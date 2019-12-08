#!/usr/bin/perl
#
# This code was forked from the LiveJournal project owned and operated
# by Live Journal, Inc. The code has been modified and expanded by
# Dreamwidth Studios, LLC. These files were originally licensed under
# the terms of the license supplied by Live Journal, Inc, which can
# currently be found at:
#
# http://code.livejournal.org/trac/livejournal/browser/trunk/LICENSE-LiveJournal.txt
#
# In accordance with the original license, this code and all its
# modifications are provided under the GNU General Public License.
# A copy of that license can be found in the LICENSE file included as
# part of this distribution.

package LJ;

use strict;
use v5.10;
use Log::Log4perl;
my $log = Log::Log4perl->get_logger(__PACKAGE__);

use Encode qw( encode from_to );
use IO::Socket::INET;
use Mail::Address;
use MIME::Base64 qw( encode_base64 );
use MIME::Lite;
use MIME::Words qw( encode_mimeword );
use Text::Wrap ();
use Time::HiRes qw( gettimeofday tv_interval );

use DW::Stats;
use DW::Task::SendEmail;
use LJ::CleanHTML;

# <LJFUNC>
# name: LJ::send_mail
# des: Sends email.  Character set will only be used if message is not ASCII.
# args: opt, async_caller
# des-opt: Hashref of arguments.  Required: to, from, subject, body.
#          Optional: toname, fromname, cc, bcc, charset, wrap, html.
#          All text must be in UTF-8 (without UTF flag, as usual in LJ code).
#          Body and subject are converted to recipient-user mail encoding.
#          Subject line is encoded according to RFC 2047.
#          Warning: opt can be a MIME::Lite ref instead, in which
#          case it is sent as-is.
# </LJFUNC>
sub send_mail {
    my $opt          = shift;
    my $async_caller = shift;

    my $msg = $opt;

    # Record stats about who called us. This is pretty gross, but there are many, many
    # callers so it seems easier to amend this instead of going back and redefining
    # the LJ::send_mail API. For now.
    my ( $package, $filename, $line ) = caller;
    DW::Stats::increment( 'dw.mail.send', 1, [ 'caller:' . "$package/$line" ] );

    # did they pass a MIME::Lite object already?
    unless ( ref $msg eq 'MIME::Lite' ) {

        my $clean_name = sub {
            my ( $name, $email ) = @_;
            return $email unless $name;
            $name =~ s/[\n\t\"<>]//g;
            return $name ? "\"$name\" <$email>" : $email;
        };

        my $body     = $opt->{'wrap'} ? Text::Wrap::wrap( '', '', $opt->{'body'} ) : $opt->{'body'};
        my $subject  = $opt->{'subject'};
        my $fromname = $opt->{'fromname'};

        # if it's not ascii, add a charset header to either what we were explictly told
        # it is (for instance, if the caller transcoded it), or else we assume it's utf-8.
        # Note: explicit us-ascii default charset suggested by RFC2854 sec 6.
        $opt->{'charset'} ||= "utf-8";
        my $charset;
        if (   !LJ::is_ascii($subject)
            || !LJ::is_ascii($body)
            || ( $opt->{html} && !LJ::is_ascii( $opt->{html} ) )
            || !LJ::is_ascii($fromname) )
        {
            $charset = $opt->{'charset'};
        }
        else {
            $charset = 'us-ascii';
        }

        # Don't convert from us-ascii and utf-8 charsets.
        unless ( ( $charset =~ m/us-ascii/i ) || ( $charset =~ m/^utf-8$/i ) ) {
            from_to( $body, "utf-8", $charset );

            # Convert also html-part if we has it.
            if ( $opt->{html} ) {
                from_to( $opt->{html}, "utf-8", $charset );
            }
        }

        from_to( $subject, "utf-8", $charset ) unless $charset =~ m/^utf-8$/i;
        if ( !LJ::is_ascii($subject) ) {
            $subject = MIME::Words::encode_mimeword( $subject, 'B', $charset );
        }

        from_to( $fromname, "utf-8", $charset ) unless $charset =~ m/^utf-8$/i;
        if ( !LJ::is_ascii($fromname) ) {
            $fromname = MIME::Words::encode_mimeword( $fromname, 'B', $charset );
        }
        $fromname = $clean_name->( $fromname, $opt->{'from'} );

        if ( $opt->{html} ) {

            # do multipart, with plain and HTML parts

            $msg = new MIME::Lite(
                'From'    => $fromname,
                'To'      => $clean_name->( $opt->{'toname'}, $opt->{'to'} ),
                'Cc'      => $opt->{cc} || '',
                'Bcc'     => $opt->{bcc} || '',
                'Subject' => $subject,
                'Type'    => 'multipart/alternative'
            );

            # add the plaintext version
            my $plain = $msg->attach(
                'Type'     => 'text/plain',
                'Data'     => "$body\n",
                'Encoding' => 'quoted-printable',
            );
            $plain->attr( "content-type.charset" => $charset );

            # add the html version
            my $html = $msg->attach(
                'Type'     => 'text/html',
                'Data'     => $opt->{html},
                'Encoding' => 'quoted-printable',
            );
            $html->attr( "content-type.charset" => $charset );

        }
        else {
            # no html version, do simple email
            $msg = new MIME::Lite(
                'From'     => $fromname,
                'To'       => $clean_name->( $opt->{'toname'}, $opt->{'to'} ),
                'Cc'       => $opt->{cc} || '',
                'Bcc'      => $opt->{bcc} || '',
                'Subject'  => $subject,
                'Type'     => 'text/plain',
                'Data'     => $body,
                'Encoding' => 'quoted-printable'
            );

            $msg->attr( "content-type.charset" => $charset );
        }

        if ( $opt->{headers} ) {
            while ( my ( $tag, $value ) = each %{ $opt->{headers} } ) {
                $msg->add( $tag, $value );
            }
        }
    }

    # at this point $msg is a MIME::Lite

    # Enqueue in the task system for sending out by a worker
    my $starttime = [ gettimeofday() ];
    my ($env_from) = map { $_->address } Mail::Address->parse( $msg->get('From') );
    my @rcpts;
    push @rcpts, map { $_->address } Mail::Address->parse( $msg->get($_) ) foreach (qw(To Cc Bcc));
    my $host;
    if ( @rcpts == 1 ) {
        $rcpts[0] =~ /(.+)@(.+)$/;
        $host = lc($2) . '@' . lc($1);    # we store it reversed in database
    }
    my $h = DW::TaskQueue->dispatch(
        DW::Task::SendEmail->new(
            {
                env_from => $env_from,
                rcpts    => \@rcpts,
                data     => $msg->as_string,
            },
        )
    );
    return $h ? 1 : 0;
}

=head2 C<< LJ::send_formatted_mail( %opts ) >>

Wrapper around LJ::send_mail.

Sends an email in the form of:

[[greeting]],
[[body as plaintext/html]]
[[footer]]

The greeting and footer are generated automatically. The body must not include these.

Required arguments:

=over
=item to - email address
=item from - email address
=item subject
=item body - The body is formatted automatically using Markdown; there's no need to do any text processing yourself.
=back

Optional arguments:
=over
=item greeting_user - the name to greet this user by. If not provided, we don't show the greeting
=item toname - display name
=item fromname - display name
=item cc
=item bcc
=item charset
=back


=cut

sub send_formatted_mail {
    my (%opts) = @_;

    my ( $html_body, $plain_body ) = LJ::format_mail( $opts{body}, $opts{greeting_user} );
    return LJ::send_mail(
        {
            to      => $opts{to},
            from    => $opts{from},
            subject => $opts{subject},

            body => $plain_body,
            html => $html_body,

            toname   => $opts{toname},
            fromname => $opts{fromname},
            cc       => $opts{cc},
            bcc      => $opts{bcc},
            charset  => $opts{charset},
        }
    );
}

=head2 C<< LJ::format_mail( $text )>>

Returns the formatted version of the text as a list of: ( $html_body, $plaintext_body )

Automatically appends greeting and footer.

=cut

sub format_mail {
    my ( $text, $greeting_user ) = @_;

    my $greeting =
        $greeting_user ? LJ::Lang::ml( "email.greeting", { user => $greeting_user } ) : "";
    my $footer = LJ::Lang::ml( "email.footer",
        { sitename => $LJ::SITENAMESHORT, siteroot => $LJ::SITEROOT } );

    $text = "$greeting\n\n$text\n\n$footer";

    # use markdown to format from text to HTML
    my $html = $text;
    my $opts = {};
    LJ::CleanHTML::clean_as_markdown( \$html, $opts );

    # run this cleaner to convert any user tags that turn up post-markdown
    LJ::CleanHTML::clean_event( \$html, $opts );

# use plaintext as-is, but look for "[links like these](url)", and change them to "links like these (url)"
    my $plaintext = LJ::strip_html($text);
    $plaintext =~ s/\[(.*?)\]\(/$1 (/g;

    return ( $html, $plaintext );
}
1;
