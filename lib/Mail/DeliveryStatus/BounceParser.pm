package Mail::DeliveryStatus::BounceParser;

=head1 NAME

Mail::DeliveryStatus::BounceParser - Perl extension to analyze bounce messages

=head1 SYNOPSIS

  use Mail::DeliveryStatus::BounceParser;

  # $message is \*io or $fh or "entire\nmessage" or \@lines
  my $bounce = eval { Mail::DeliveryStatus::BounceParser->new($message); };

  if ($@) {
    # couldn't parse.
  }

  my @addresses       = $bounce->addresses;       # email address strings
  my @reports         = $bounce->reports;         # Mail::Header objects
  my $orig_message_id = $bounce->orig_message_id; # <ABCD.1234@mx.example.com>
  my $orig_message    = $bounce->orig_message;    # Mail::Internet object

=head1 ABSTRACT

Mail::DeliveryStatus::BounceParser analyzes RFC822 bounce messages and returns
a structured description of the addresses that bounced and the reason they
bounced; it also returns information about the original returned message
including the Message-ID.  It works best with RFC1892 delivery reports, but
will gamely attempt to understand any bounce message no matter what MTA
generated it.

=head1 DESCRIPTION

Meng Wong wrote this for the Listbox v2 project; good mailing list managers
handle bounce messages so listowners don't have to.  The best mailing list
managers figure out exactly what is going on with each subscriber so the
appropriate action can be taken.

=cut

use 5.00503;
use strict;

$Mail::DeliveryStatus::BounceParser::VERSION = '1.512';

use MIME::Parser;
use Mail::DeliveryStatus::Report;

my $Not_An_Error = qr/
    \b delayed \b
  | \b warning \b
  | transient.{0,20}\serror
  | Your \s message .{0,100} was \s delivered \s to \s the \s following \s recipient
/six;

my $Really_An_Error = qr/this is a permanent error/i;

my $Returned_Message_Below = qr/(
    (?:original|returned) \s message \s (?:follows|below)
  | (?: this \s is \s a \s copy \s of
      | below \s this \s line \s is \s a \s copy
    ) .{0,100} \s message
  | message \s header \s follows
  | ^ (?:return-path|received|from):
)/sixm;

my @Preprocessors = qw(
  p_ms
  p_ims
  p_compuserve
  p_aol_senderblock
  p_novell_groupwise_5_2
  p_aol_bogus_250
  p_plain_smtp_transcript
  p_xdelivery_status
);

=head2 parse

  my $bounce = Mail::DeliveryStatus::BounceParser->parse($message, \%arg);

OPTIONS.  If you pass BounceParser->new(..., {log=>sub { ... }}) That will be
used as a logging callback.

NON-BOUNCES.  If the message is recognizably a vacation autoresponse, or is a
report of a transient nonfatal error, or a spam or virus autoresponse, you'll
still get back a C<$bounce>, but its C<<$bounce->is_bounce()>> will return
false.

It is possible that some bounces are not really bounces; for example, when
Hotmail responds with 554 Transaction Failed, that just means hotmail was
overloaded at the time, so the user actually isn't bouncing.  To include such
non-bounces in the reports, pass the option {report_non_bounces=>1}.

For historical reasons, C<new> is an alias for the C<parse> method.

=cut

sub parse {
  my ($class, $data, $arg) = @_;
  # my $bounce = Mail::DeliveryStatus::BounceParser->new( \*STDIN | $fh |
  # "entire\nmessage" | ["array","of","lines"] );

  my $parser = new MIME::Parser;
     $parser->output_to_core(1);
  my $message;

  if (not $data) {
    print STDERR "BounceParser: expecting bounce mesage on STDIN\n" if -t STDIN;
    $message = $parser->parse(\*STDIN);
  } elsif (not ref $data)        {
    $message = $parser->parse_data($data);
  } elsif (ref $data eq "ARRAY") {
    $message = $parser->parse_data($data);
  } else {
    $message = $parser->parse($data);
  }

  my $self = bless {
    reports   => [],
    is_bounce => 1,
    log       => $arg->{log},
    parser    => $parser,
    orig_message_id => undef,
  }, $class;

  $self->log(
    "received message with type "
    . $message->effective_type
    . ", subject "
    . $message->head->get("subject")
  );

  # before we even start to analyze the bounce, we recognize certain special
  # cases, and rewrite them to be intelligible to us
  foreach my $preprocessor (@Preprocessors) {
    if (my $newmessage = $self->$preprocessor($message)) {
      $message = $newmessage;
    }
  }

  $self->{message} = $message;

  $self->log(
    "now the message is type "
    . $message->effective_type
    . ", subject "
    . $message->head->get("subject")
  );

  my $first_part = _first_non_multi_part($message);

  # we'll deem autoreplies to be usually less than a certain size.

  # Some vacation autoreplies are (sigh) multipart/mixed, with an additional
  # part containing a pointless disclaimer; some are multipart/alternative,
  # with a pointless HTML part saying the exact same thing.  (Messages in
  # this latter category have the decency to self-identify with things like
  # '<META NAME="Generator" CONTENT="MS Exchange Server version
  # 5.5.2653.12">', so we know to avoid such software in future.)  So look
  # at the first part of a multipart message (recursively, down the tree).

  {
    last if $message->effective_type eq 'multipart/report';
    last if !$first_part || $first_part->effective_type ne 'text/plain';
    my $string = $first_part->as_string;
    last if length($string) > 3000;
    last if $string !~ /auto.{0,20}reply|vacation|(out|away|on holiday).*office/i;
    $self->log("looks like a vacation autoreply, ignoring.");
    $self->{type} = "vacation autoreply";
    $self->{is_bounce} = 0;
    return $self;
  }


  # "Email address changed but your message has been forwarded"
  {
    last if $message->effective_type eq 'multipart/report';
    last if !$first_part || $first_part->effective_type ne 'text/plain';
    my $string = $first_part->as_string;
    last if length($string) > 3000;
    last if $string
      !~ /(address .{0,60} changed | domain .{0,40} retired) .*
          (has\s*been|was|have|will\s*be) \s* (forwarded|delivered)/six;
    $self->log('looks like an address-change autoreply, ignoring');
    $self->{type} = 'informational address-change autoreply';
    $self->{is_bounce} = 0;
    return $self;
  }

  # Network Associates WebShield SMTP V4.5 MR1a on cpwebshield intercepted a
  # mail from <owner-aftermba@v2.listbox.com> which caused the Content Filter
  # Block extension COM to be triggered.
  if ($message->effective_type eq "text/plain"
      and (length $message->as_string) < 3000
      and $message->bodyhandle->as_string
        =~ m/norton\sassociates\swebshield|content\s+filter/ix
  ) {
    $self->log("looks like a virus/spam block, ignoring.");
    $self->{type} = "virus/spam false positive";
    $self->{is_bounce} = 0;
    return $self;
  }

  # nonfatal errors usually say they're transient

  if ($message->effective_type eq "text/plain"
    and $message->bodyhandle->as_string =~ /transient.*error/is) {
    $self->log("seems like a nonfatal error, ignoring.");
    $self->{is_bounce} = 0;
    return $self;
  }

  # jkburns@compuserve.com has a new CompuServe e-mail address.  The new e-mail
  # address is johnkingburns@cs.com and CompuServe has automatically forwarded
  # your message. Please take this opportunity to update your address book with
  # the new e-mail address.
  if ($message->effective_type eq "text/plain") {
    my $string = $message->bodyhandle->as_string;
    my $forwarded_pos
      = _match_position($string, qr/automatically.{0,40}forwarded/is);

    my $orig_msg_pos 
      = _match_position($string, $Returned_Message_Below);
    if (
      defined($forwarded_pos)
      && _position_before($forwarded_pos, $orig_msg_pos)
    ) {
      $self->log("message forwarding notification, ignoring");
      $self->{is_bounce} = 0;
      return $self;
    }
  }

  # nonfatal errors usually say they're transient, but sometimes they do it
  # straight out and sometimes it's wrapped in a multipart/report.
  #
  # Be careful not to examine a returned body for the transient-only signature:
  # $Not_An_Error can match the single words 'delayed' and 'warning', which
  # could quite reasonably occur in the body of the returned message.  This
  # also means it's worth additionally checking for a regex that gives a very
  # strong indication that the error was permanent.
  {
    my $part_for_maybe_transient;
    $part_for_maybe_transient = $message
      if $message->effective_type eq "text/plain";
    $part_for_maybe_transient
      = grep { $_->effective_type eq "text/plain" } $message->parts
        if $message->effective_type =~ /multipart/
           && $message->effective_type ne 'multipart/report';

    if ($part_for_maybe_transient) {
      my $string = $part_for_maybe_transient->bodyhandle->as_string;
      my $transient_pos = _match_position($string, $Not_An_Error);
      last unless defined $transient_pos;
      my $permanent_pos = _match_position($string, $Really_An_Error);
      my $orig_msg_pos  = _match_position($string, $Returned_Message_Below);
      last if _position_before($permanent_pos, $orig_msg_pos);
      if (_position_before($transient_pos, $orig_msg_pos)) {
        $self->log("transient error, ignoring.");
        $self->{is_bounce} = 0;
        return $self;
      }
    }
  }

  # In all cases we will read the message body to try to pull out a message-id.
  if ($message->effective_type =~ /multipart/) {
    # "Internet Mail Service" sends multipart/mixed which still has a
    # message/rfc822 in it
    if (
      my ($orig_message) =
        grep { $_->effective_type eq "message/rfc822" } $message->parts
    ) {
      # see MIME::Entity regarding REPLACE
      my $orig_message_id = $orig_message->parts(0)->head->get("message-id");
      chomp $orig_message_id;
      $self->log("extracted original message-id $orig_message_id from the original rfc822/message");
      $self->{orig_message_id} = $orig_message_id;
      $self->{orig_message} = $orig_message->parts(0);
    }

    # todo: handle pennwomen-la@v2.listbox.com/200209/19/1032468832.1444_1.frodo
    # which is a multipart/mixed containing an application/tnef instead of a
    # message/rfc822.  yow!

    if (! $self->{orig_message_id}
	     and
	     my ($rfc822_headers) =
         grep { lc $_->effective_type eq "text/rfc822-headers" } $message->parts
    ) {
      my $orig_head = Mail::Header->new($rfc822_headers->body);
      chomp ($self->{orig_message_id} = $orig_head->get("message-id"));
      $self->{orig_header} = $orig_head;
      $self->log("extracted original message-id $self->{orig_message_id} from text/rfc822-headers");
    }
  }

  if (! $self->{orig_message_id}) {
    if ($message->bodyhandle and $message->bodyhandle->as_string =~ /Message-ID: (\S+)/i) {
      $self->{orig_message_id} = $1;
      $self->log("found a message-id $self->{orig_message_id} in the body.");
    }
  }

  if (! $self->{orig_message_id}) {
    $self->log("couldn't find original message id.");
  }


  #
  # try to extract email addresses to identify members.
  # we will also try to extract reasons as much as we can.
  #

  if ($message->effective_type eq "multipart/report") {
    my ($delivery_status) = grep { $_->effective_type eq "message/delivery-status" } $message->parts;

    # $self->log("examining multipart/report...") if $DEBUG > 3;

    my %global = ("reporting-mta" => undef, "arrival-date"  => undef);

    my ($seen_action_expanded, $seen_action_failed);

    # Some MTAs generate malformed multipart/report messages with no
    # message/delivery-status part; don't die in such cases.
    my $delivery_status_body
      = eval { $delivery_status->bodyhandle->as_string } || '';

    foreach my $para (split /\n\n/, $delivery_status_body) {
      my $report = Mail::Header->new([split /\n/, $para]);
      $report->combine();
      $report->unfold;

      # Some MTAs send unsought delivery-status notifications indicating
      # success; others send RFC1892/RFC3464 delivery status notifications
      # for transient failures.
      if (my $action = lc $report->get('Action')) {
        $action =~ s/^\s+//;
        if ($action =~ s/^\s*([a-z]+)\b.*/$1/s) {
          # In general, assume that anything other than 'failed' is a
          # non-bounce; but 'expanded' is handled after the end of this
          # foreach loop, because it might be followed by another
          # per-recipient group that says 'failed'.
          if ($action eq 'expanded') {
            $seen_action_expanded = 1;
          } elsif ($action eq 'failed') {
            $seen_action_failed   = 1;
          } else {
            $self->log("message/delivery-status says 'Action: \L$1'");
            $self->{type} = 'delivery-status \L$1';
            $self->{is_bounce} = 0;
            return $self;
          }
        }
      }

      for (qw(Reporting-MTA Arrival-Date)) {
        $report->replace($_ => $global{$_} ||= $report->get($_))
      }

      next unless my $email = $report->get("original-recipient")
                           || $report->get("final-recipient");

      # $self->log("email = \"$email\"") if $DEBUG > 3;

      # Diagnostic-Code: smtp; 550 5.1.1 User unknown
      my $reason = $report->get("diagnostic-code");

      $email  =~ s/[^;]+;\s*//; # strip leading RFC822; or LOCAL; or system;
      $reason =~ s/[^;]+;\s*//; # strip leading X-Postfix;

      $email = _cleanup_email($email);

      $report->replace(email      => $email);
      $report->replace(reason     => $reason);
      $report->replace(std_reason => _std_reason($report->get("diagnostic-code")));
      $report->replace(
        host => ($report->get("diagnostic-code") =~ /\bhost\s+(\S+)/)
      );

      $report->replace(
        smtp_code => ($report->get("diagnostic-code") =~ /((\d{3})\s|\s(\d{3})(?!\.))/)[0]
      );

      if (not $report->get("host")) {
        $report->replace(host => ($report->get("email") =~ /\@(.+)/)[0])
      }

      if ($report->get("smtp_code") =~ /^2../) {
        $self->log(
          "smtp code is "
          . $report->get("smtp_code")
          . "; no_problemo."
        );

        unless ($report->get("host") =~ /\baol\.com$/i) {
          $report->replace(std_reason => "no_problemo");
        } else {
          $self->log("but it's aol telling us that; not going to believe it.");
        }
      }

      unless ($arg->{report_non_bounces}) {
        if ($report->get("std_reason") eq "no_problemo") {
          $self->log(
            "not actually a bounce: " . $report->get("diagnostic-code")
          );
          next;
        }
      }

      # $self->log("learned about $email: " . $report->get("std_reason")) if
      # $DEBUG > 3;

      push @{$self->{reports}},
        Mail::DeliveryStatus::Report->new([ split /\n/, $report->as_string ]
      );
    }

    if ($seen_action_expanded && !$seen_action_failed) {
      # We've seen at least one 'Action: expanded' DSN-field, but no
      # 'Action: failed'
      $self->log(q[message/delivery-status says 'Action: expanded']);
      $self->{type} = 'delivery-status expanded';
      $self->{is_bounce} = 0;
      return $self;
    }
  } elsif ($message->effective_type =~ /multipart/) {
    # but not a multipart/report.  look through each non-message/* section.

    # $self->log("examining non-report multipart...") if $DEBUG > 3;

    # generated by IMS:
    #
    # Your message
    #
    #  To:      thood@edify.com
    #  Subject: Red and Blue Online - October 2002
    #  Sent:    Tue, 15 Oct 2002 13:08:24 -0700
    #
    # did not reach the following recipient(s):
    #
    # thood@eagle on Tue, 15 Oct 2002 13:18:39 -0700
    #     The recipient name is not recognized
    #         The MTS-ID of the original message is: c=us;a=
    # ;p=edify;l=EAGLE02101520184GF2XLBD
    #  MSEXCH:IMS:EDIFY:CORP:EAGLE 0 (000C05A6) Unknown Recipient
    #

    my @delivery_status_parts = grep {
      $_->effective_type !~ /rfc822|html/ and not $_->is_multipart
    } $message->parts;

    # $self->log("error parts: @{[ map { $_->bodyhandle->as_string }
    # @delivery_status_parts ]}") if $DEBUG > 3;

    push @{$self->{reports}}, $self->_extract_reports(@delivery_status_parts);

  } else {
    # handle plain-text responses

    # they usually say "returned message" somewhere, and we can split on that,
    # above and below.

    if (($message->bodyhandle->as_string||'') =~ $Returned_Message_Below) {
      my ($stuff_before, $stuff_splitted, $stuff_after) =
        split $Returned_Message_Below, $message->bodyhandle->as_string, 3;
      # $self->log("splitting on \"$stuff_splitted\", " . length($stuff_before)
      # . " vs " . length($stuff_after) . " bytes.") if $DEBUG > 3;
      push @{$self->{reports}}, $self->_extract_reports($stuff_before);
      $self->{orig_text} = $stuff_before;
    } elsif (/(.+)\n\n(.+?Message-ID:.+)/is) {
      push @{$self->{reports}}, $self->_extract_reports($1);
      $self->{orig_text} = $2;
    } else {
      push @{$self->{reports}},
        $self->_extract_reports($message->bodyhandle->as_string);
      $self->{orig_text} = $message->bodyhandle->as_string;
    }
  }
  return $self;
}

BEGIN { *new = \&parse };

=head2 log

  $bounce->log($messages);

If a logging callback has been given, the message will be passed to it.

=cut

sub log {
  my ($self, @log) = @_;
  if (ref $self->{log} eq "CODE") {
    $self->{log}->(@_);
  }
  return 1;
}

sub _extract_reports {
  my $self = shift;
  # input: either a list of MIME parts, or just a chunk of text.

  if (@_ > 1) { return map { _extract_reports($_) } @_ }

  my $text = shift;

  $text = $text->bodyhandle->as_string if ref $text;

  my %by_email;

  # we'll assume that the text is made up of:
  # blah blah 0
  #             email@address 1
  # blah blah 1
  #             email@address 2
  # blah blah 2
  #

  foreach my $line (split/\n/, $text) {
    # $self->log("-ext- looking for error in $line") if $DEBUG > 3;
  }

  # we'll break it up accordingly, and first try to detect a reason for email 1
  # in section 1; if there's no reason returned, we'll look in section 0.  and
  # we'll keep going that way for each address.

  my @split = split(/(\S+\@\S+)/, $text);

  foreach my $i (0 .. $#split) {
    # only interested in the odd numbered elements, which are the email
    # addressess.
    next if $i % 2 == 0;

    my $email = _cleanup_email($split[$i]);

    if ($split[$i-1] =~ /they are not accepting mail from/) {
      # aol airmail sender block $self->log("$email is not actually a bouncing
      # address...") if $DEBUG > 3;
      next;
    }

    # $self->log("looking for the reason that $email bounced...") if $DEBUG > 3;

    my $std_reason = "unknown";
    $std_reason = _std_reason($split[$i+1]) if $#split > $i;
    $std_reason = _std_reason($split[$i-1]) if $std_reason eq "unknown";

    # todo:
    # if we can't figure out the reason, if we're in the delivery-status part,
    # go back up into the text part and try extract_report() on that.

    # $self->log("reason: $std_reason") if $DEBUG > 3;

    next if (
      exists $by_email{$email}
      and $by_email{$email}->{std_reason}
      ne "unknown" and $std_reason eq "unknown"
    );

    $by_email{$email} = {
      email => $email,
      raw   => join ("", @split[$i-1..$i+1]),
      std_reason => $std_reason,
    };
  }

  my @toreturn;

  foreach my $email (keys %by_email) {
    my $report = Mail::DeliveryStatus::Report->new();
    $report->header_hashref($by_email{$email});
    push @toreturn, $report;
  }

  return @toreturn;
}

=head2 is_bounce

  if ($bounce->is_bounce) { ... }

This method returns true if the bounce parser thought the message was a bounce,
and false otherwise.

=cut

sub is_bounce { return shift->{is_bounce}; }

=head2 reports

Each $report returned by $bounce->reports() is basically a Mail::Header object
with a few modifications.  It includes the email address bouncing, and the
reason for the bounce.

Consider an RFC1892 error report of the form

 Reporting-MTA: dns; hydrant.pobox.com
 Arrival-Date: Fri,  4 Oct 2002 16:49:32 -0400 (EDT)

 Final-Recipient: rfc822; bogus3@dumbo.pobox.com
 Action: failed
 Status: 5.0.0
 Diagnostic-Code: X-Postfix; host dumbo.pobox.com[208.210.125.24] said: 550
  <bogus3@dumbo.pobox.com>: Nonexistent Mailbox

Each "header" above is available through the usual get() mechanism.

  print $report->get('reporting_mta');   # 'some.host.com'
  print $report->get('arrival-date');    # 'Fri,  4 Oct 2002 16:49:32 -0400 (EDT)'
  print $report->get('final-recipient'); # 'rfc822; bogus3@dumbo.pobox.com'
  print $report->get('action');          # "failed"
  print $report->get('status');          # "5.0.0"
  print $report->get('diagnostic-code'); # X-Postfix; ...

  # BounceParser also inserts a few interpretations of its own:
  print $report->get('email');           # 'bogus3@dumbo.pobox.com'
  print $report->get('std_reason');      # 'user_unknown'
  print $report->get('reason');          # host [199.248.185.2] said: 550 5.1.1 unknown or illegal user: somebody@uss.com
  print $report->get('host');            # dumbo.pobox.com
  print $report->get('smtp_code');       # 550

  print $report->get('raw') ||           # the original unstructured text
        $report->as_string;              # the original   structured text

Probably the two most useful fields are "email" and "std_reason", the
standardized reason.  At this time BounceParser returns the following
standardized reasons:

  user_unknown
  over_quota
  domain_error
  unknown
  no_problemo

(no_problemo will only appear if you set {report_non_bounces=>1})

If the bounce message is not structured according to RFC1892, BounceParser will
still try to return as much information as it can; in particular, you can count
on "email" and "std_reason" to be present.

=cut

sub reports { return @{shift->{reports}} }

=head2 addresses

Returns a list of the addresses which appear to be bouncing.  Each member of
the list is an email address string of the form 'foo@bar.com'.

=cut

sub addresses { return map { $_->get("email") } shift->reports; }

=head2 orig_message_id

If possible, returns the message-id of the original message as a string.

=cut

sub orig_message_id { return shift->{orig_message_id}; }

=head2 orig_message

If the original message was included in the bounce, it'll be available here as
a message/rfc822 MIME entity.

  my $orig_message    = $bounce->orig_message;

=cut

sub orig_message { return shift->{orig_message} }

=head2 orig_header

If only the original headers were returned in the text/rfc822-headers chunk,
they'll be available here as a Mail::Header entity.

=cut

sub orig_header { return shift->{orig_header} }

=head2 orig_text

If the bounce message was poorly structured, the above two methods won't return
anything --- instead, you get back a block of text that may or may not
approximate the original message.  No guarantees.  Good luck.

=cut

sub orig_text { return shift->{orig_text} }

=head1 CAVEATS

Bounce messages are generally meant to be read by humans, not computers.  A
poorly formatted bounce message may fool BounceParser into spreading its net
too widely and returning email addresses that didn't actually bounce.  Before
you do anything with the email addresses you get back, confirm that it makes
sense that they might be bouncing --- for example, it doesn't make sense for
the sender of the original message to show up in the addresses list, but it
could if the bounce message is sufficiently misformatted.

Still, please report all bugs!

=head1 FREE-FLOATING ANXIETY

Some bizarre MTAs construct bounce messages using the original headers of the
original message.  If your application relies on the assumption that all
Message-IDs are unique, you need to watch out for these MTAs and program
defensively; before doing anything with the Message-ID of a bounce message,
first confirm that you haven't already seen it; if you have, change it to
something else that you make up on the spot, such as
"<antibogus-TIMESTAMP-PID-COUNT@LOCALHOST>".

=head1 BUGS

BounceParser assumes a sanely constructed bounce message.  Input from the real
world may cause BounceParser to barf and die horribly when we violate one of
MIME::Entity's assumptions; this is why you should always call it inside an
eval { }.

=head2 TODO

Provide some translation of the SMTP and DSN error codes into English.  Review
RFC1891 and RFC1893.

=head1 KNOWN TO WORK WITH

We understand bounce messages generated by the following MTAs / organizations:

 postfix
 sendmail
 qmail
 Exim
 IMS
 Morgan Stanley (ms.com) and emory.edu
 AOL's AirMail sender-blocking
 Novell Groupwise

=head1 SEE ALSO

  Used by http://listbox.com/ --- if you like BounceParser and you know it,
  consider Listbox for your mailing list needs!

  Ironically, BounceParser has no mailing list or web site at this time.

  See RFC1892, the Multipart/Report Content Type.

=head1 RANDOM OBSERVATION

Schwern's modules have the Alexandre Dumas property.

=head1 AUTHOR

Original author: Meng Weng Wong, E<lt>mengwong+bounceparser@pobox.comE<gt>

Current maintainer: Ricardo SIGNES, E<lt>rjbs@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

  Copyright (C) 2003-2006, IC Group, Inc.
	pobox.com permanent email forwarding with spam filtering
  listbox.com mailing list services for announcements and discussion

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 WITH A SHOUT OUT TO

  coraline, Fletch, TorgoX, mjd, a-mused, Masque, gbarr,
  sungo, dngor, and all the other hoopy froods on #perl

=cut

sub _std_reason {
  local $_ = shift;

  if (/(domain|host)\s+not\s+found/i) { return "domain_error" }

  if (
    /try.again.later/is or
    /mailbox\b.*\bfull/ or
    /storage/i          or
    /quota/i
  ) {
    return "over_quota";
  }

  if (
    /unknown/i or
    /disabled|discontinued/is or
    /can't\s+open/is or
    /invalid/is or
    /permanent/is or
    /unauthorized/is or
    /unavailable/is or
    /not(\s+a)?\s+(found|known|listed|valid|recogni|present|exist|activ|allow)/i or
    /\bno\s+(email|such|mailbox)/i or
    /unknown|inactive|suspended|cancel+ed/i or
    /doesn\'t/is or
    /5\.1\.1/
  ) {
    return "user_unknown";
  }

  if (
    /domain\s+syntax/i or
    /timed\s+out/i or
    /route\s+to\s+host/i or
    /connection\s+refused/i or
    /relay/i or
    /no\s+data\s+record\s+of\s+requested\s+type/i
  ) {
    return "domain_error";
  } elsif (/hotmail.+transaction\s+failed/is) {
    # next if it's hotmail and they reject 554 transaction failed; that just
    # means their system is too loaded.
    return "no_problemo";
  }

  return "unknown";
}

# ---------------------------------------------------------------------
# 		       preprocessors
# ---------------------------------------------------------------------

sub p_ms {
  my $self    = shift;
  my $message = shift;
  my $domain = qr(ms\.com|emory\.edu|wharton\.upenn\.edu|midway\.uchicago\.edu)i;

  # From: Mail Delivery Subsystem <MAILER-DAEMON@ms.com>
  # Subject: Undeliverable Mail
  # X-Listbox-Reason: samantha.wright@msdw.com user unknown
  # Lines: 116
  #
  #    ----- The following addresses had permanent fatal errors -----
  #
  # wrights: User unknown
  #
  #    ----- Original message follows -----
  #
  # Received: from hqvsbh1.ms.com (hqvsbh1-i0.morgan.com [199.89.99.101])
  #         by pismh4.ms.com (8.8.5/imap+ldap v2.4) with ESMTP id QAA23003
  #         for <wrights@ms.com>; Thu, 19 Sep 2002 16:52:55 -0400 (EDT)
  # Received: from hqvsbh1.ms.com (localhost [127.0.0.1])
  #         by localhost.ms.com (Postfix) with SMTP id 35090205D5
  #         for <samantha.wright@msdw.com>; Thu, 19 Sep 2002 16:52:55 -0400 (EDT)

  # -------------------------------------------------- case 2

  # 20030218-02:00:53 root@frodo:~listbox/Archive# less afe-chicago@v2.listbox.com/200209/18/1032373917.29028_1.frodo
  # Return-Path: <>
  # Delivered-To: listbox+trampoline+282+137642+ec84f782@frodo.listbox.com
  # Received: from juliet.cc.emory.edu (juliet.cc.emory.edu [170.140.204.2])
  #         by frodo.listbox.com (Postfix) with ESMTP id E9BF78038
  #         for <listbox+trampoline+282+137642+ec84f782@v2.listbox.com>; Wed, 18 Sep 2002 12:41:29 -0400 (EDT)
  # Received: (from root@localhost)
  #         by juliet.cc.emory.edu (8.10.2/8.10.2) with X.500 id g8IGfTN03537
  #         for listbox+trampoline+282+137642+ec84f782@v2.listbox.com; Wed, 18 Sep 2002 12:41:29 -0400 (EDT)
  # Date: Wed, 18 Sep 2002 12:41:29 -0400 (EDT)
  # Message-Id: <200209181641.g8IGfTN03537@juliet.cc.emory.edu>
  # To: listbox+trampoline+282+137642+ec84f782@v2.listbox.com
  # From: MAILER-DAEMON@emory.edu
  # Subject: undeliverable mail for rchiri
  # X-Listbox-Reason: rchiri@emory.edu user unknown
  # Lines: 68
  #
  # The following errors occurred when trying to deliver the attached mail:
  #
  # rchiri: User unknown
  #
  # ------- The original message sent:
  #
  # Received: from frodo.listbox.com (frodo.listbox.com [208.210.125.58])
  #         by juliet.cc.emory.edu (8.10.2/8.10.2) with ESMTP id g8IGfT003531
  #         for <rchiri@emory.edu>; Wed, 18 Sep 2002 12:41:29 -0400 (EDT)
  # Received: by frodo.listbox.com (Postfix, from userid 1003)
  #         id C5DBE8036; Wed, 18 Sep 2002 12:41:28 -0400 (EDT)

  # ------------------------------------------------------------ case 3
  #  afe-chicago@v2.listbox.com/200209/18/1032373971.29028_1.frodo
  #  afe-chicago@v2.listbox.com/200209/18/1032373938.29028_1.frodo

  # From: MAILER-DAEMON@wharton.upenn.edu
  # Message-Id: <200209181642.MAA14592@barter.wharton.upenn.edu>
  # To: listbox+trampoline+282+138095+03cc3f4e@v2.listbox.com
  # Subject: Returned mail - nameserver error report
  # X-Listbox-Reason: weilong.ye.wa98@wharton.upenn.edu unknown
  # Lines: 79
  #
  #  --------Message not delivered to the following:
  #
  #  weilong.ye.wa98    No matches to nameserver query
  #
  #  --------Error Detail (phquery V4.4):
  #
  #  The message, "No matches to nameserver query," is generated whenever
  #  the ph nameserver fails to locate either a ph alias or name field that
  #  matches the supplied name.  The usual causes are typographical errors or
  #  the use of nicknames.  Recommended action is to use the ph program to
  #  determine the correct ph alias for the individuals addressed.  If ph is
  #  not available, try sending to the most explicit form of the name, e.g.,
  #  if mike-fox fails, try michael-fox or michael-j-fox.
  #
  #
  #  --------Unsent Message below:
  #
  # Received: from frodo.listbox.com (frodo.listbox.com [208.210.125.58]) by barter.wharton.upenn.edu with ESMTP (8.9.3 (PHNE_18546)/8.7
  # .1) id MAA14570 for <weilong.ye.wa98@wharton.upenn.edu>; Wed, 18 Sep 2002 12:42:35 -0400 (EDT)
  # Received: by frodo.listbox.com (Postfix, from userid 1003)
  #

  # $self->log("p_ms: didn't match domain") and
  return
    unless ($message->head->get("from")||'') =~ /MAILER-DAEMON\@($domain)\b/i;

  $domain = $1;

  # $self->log("p_ms: couldn't find \"--- original message ---\" separator") and
  return unless not $message->is_multipart and
  my ($error_part, $orig_message) = split(
    /.*-----.*(?:Original message follows|The original message sent:|unsent message below).*/i,
    $message->bodyhandle->as_string
  );

  # $self->log("p_ms: couldn't find \"following message ... errors") and
  return unless $error_part =~ /The following addresses had permanent fatal errors|The following errors occurred when trying to deliver the attached mail:|message not delivered/i;

  # $self->log("p_ms: couldn't find Received: header in orig message.") and
  return unless $orig_message =~ /^Received: from/m;

  my @error_lines;
  if ($error_part =~ /error detail.*phquery/i) {
    @error_lines = (
      grep { /\S/ }
      grep { ! /error detail/i }
      grep { /message.*not delivered to the following/i .. /error detail/i }
      split /\n/, $error_part
    );
  } else {
    @error_lines = grep {
      ! /addresses had permanent fatal errors/
      &&
      /The following errors occurred when trying to deliver the attached mail:/
			&&
			/\S/
    } split /\n/, $error_part;
  }

  my @new_errors;
  foreach my $error_line (@error_lines) {
    push @new_errors, $error_line
      and next
      unless my ($address, $error) = $error_line =~ /^\s*(\S+) (.*)/;
    # $self->log("considering address $address error $error") if $DEBUG > 3;
    if ($address !~ /\@/) {
      $address = _cleanup_email($address);
      if ($orig_message =~ /for\s+<(\Q$address\E\@\S+)>/i) {
        push @new_errors, "$1: $error";
        push @new_errors, "$address\@$domain: $error";
        $self->log("p_ms: rewrote $address to $address\@$domain ($error)");
      }
    }
  }
  # $self->log("p_ms: rewrote message. new errors: @new_errors") if $DEBUG > 3;

  return $self->new_plain_report(
    $message,
    join ("\n", @new_errors),
    $orig_message
  );
}

sub p_compuserve {
  my ($self, $message) = @_;

  # afe-chicago@v2.listbox.com/200209/18/1032373866.29028_0.frodo
  # From: CompuServe Postmaster <postmaster@compuserve.com>
  # Subject: Undeliverable Message
  # Sender: CompuServe Postmaster <auto.reply@compuserve.com>
  # To: listbox+trampoline+282+137177+366d45b9@v2.listbox.com
  # X-Listbox-Reason: lallison@compuserve.com user unknown
  # Lines: 81
  #
  # Receiver not found: lallison
  #
  #
  # Your message could not be delivered as addressed.
  #
  # --- Message From Postmaster ---
  #
  # Subject: Addressing CompuServe Mail users
  #
  # Please contact postmaster@compuserve.com if you need additional formatting
  # information for other types of addresses.
  #
  # Cordially,
  #
  # The Electronic Postmaster
  #
  # --- Returned Message ---
  #
  # Sender: listbox+trampoline+282+137177+366d45b9@v2.listbox.com
  # Received: from frodo.listbox.com (frodo.listbox.com [208.210.125.58])
  #         by siaag1af.compuserve.com (8.9.3/8.9.3/SUN-1.14) with ESMTP id MAA16547
  #         for <lallison@compuserve.com>; Wed, 18 Sep 2002 12:40:17 -0400 (EDT)
  # Received: by frodo.listbox.com (Postfix, from userid 1003)
  #         id 65A1F8056; Wed, 18 Sep 2002 12:40:16 -0400 (EDT)
  #
  return if not $message->head->get("from") =~ /\@compuserve\.com/i;
  return if $message->is_multipart;
  return unless $message->bodyhandle->as_string =~ /Receiver not found:/;

  my ($stuff_before, $stuff_after)
    = split(/.*Returned Message.*/i, $message->bodyhandle->as_string);

  $stuff_before =~ s/Your message could not be delivered as addressed.*//is;

  my @new_errors;
  for (split /\n/, $stuff_before) {
    if (my ($receiver) = /Receiver not found:\s*(\S+)/) {
      if ($receiver !~ /\@/) {
        push @new_errors, "$receiver\@compuserve\.com: Receiver not found";
        next;
      }
    }
    push @new_errors, $_;
  }
  return $self->new_plain_report(
    $message,
    join ("\n", @new_errors),
    $stuff_after
  );
}

sub p_ims {
  my $self    = shift;
  my $message = shift;

  # Your message
  #
  #   To:      slpark@msx.ndc.mc.uci.edu
  #   Subject: Penn Women Paving The Way - Register Now!
  #   Sent:    Thu, 19 Sep 2002 13:40:20 -0700
  #
  # did not reach the following recipient(s):
  #
  # c=US;a= ;p=NDC;o=ORANGE;dda:SMTP=slpark@msx.ndc.mc.uci.edu; on Thu, 19 Sep
  # 2002 13:53:00 -0700
  #     The recipient name is not recognized
  #         The MTS-ID of the original message is: c=us;a=
  # ;p=ndc;l=LEA0209192052TAM7PVWM
  #     MSEXCH:IMS:NDC:ORANGE:LEA 0 (000C05A6) Unknown Recipient

  return
    unless ($message->head->get("X-Mailer")||'') =~ /Internet Mail Service/i;

  if ($message->is_multipart) {
    return unless my ($error_part)
      = grep { $_->effective_type eq "text/plain" } $message->parts;

    return unless my ($actual_error)
      = $error_part->as_string
        =~ /did not reach the following recipient\S+\s*(.*)/is;

    if (my $io = $error_part->open("w")) {
      $io->print($actual_error);
      $io->close;
    }
    # $self->log("rewrote IMS error text to " . $error_part->as_string) if
    # $DEBUG > 3;
  } else {
    # X-Mailer: Internet Mail Service (5.5.2654.52)
    # X-MS-Embedded-Report:
    # MIME-Version: 1.0
    # X-WSS-ID: 11966AB2117930-01-01
    # Content-Type: text/plain
    # Content-Transfer-Encoding: 7bit
    # X-Listbox-Reason: jfrancl@sidley.com user unknown
    # Lines: 66
    #
    # Your message
    #
    #   To:      USER_EMAIL@frodo.listbox.com
    #   Subject: You have an online postcard waiting for you!
    #   Sent:    Wed, 18 Sep 2002 11:00:36 -0500
    #
    # did not reach the following recipient(s):
    #
    # jfrancl@sidley.com on Wed, 18 Sep 2002 11:40:15 -0500
    #     The recipient name is not recognized
    #         The MTS-ID of the original message is: c=us;a= ;p=sidley
    # austin;l=CHEXCHANGE10209181640TFHKWW8X
    #     MSEXCH:IMS:Sidley & Austin:Chicago:CHEXCHANGE1 0 (000C05A6) Unknown
    # Recipient
    #
    #
    #
    # -----
    # Message-ID: <E17rhFk-00085B-00@erie.vervehosting.com>
    # From: Bonnie Eisner <owner-afe-chicago@v2.listbox.com>
    # To: USER_EMAIL@frodo.listbox.com
    #

    return unless my ($actual_error)
      = $message->bodyhandle->as_string
        =~ /did not reach the following recipient\S+\s*(.*)/is;

    my ($stuff_before, $stuff_after)
      = split /^(?=Message-ID:|Received:)/m, $message->bodyhandle->as_string;

    $stuff_before =~ s/.*did not reach the following recipient.*?$//ism;
    $self->log("rewrote IMS into plain/report.");
    return $self->new_plain_report($message, $stuff_before, $stuff_after);
  }

  return $message;
}

sub p_aol_senderblock {
  my $self    = shift;
  my $message = shift;

  # From: Mail Delivery Subsystem <MAILER-DAEMON@aol.com>
  # Date: Sun, 16 Feb 2003 19:40:22 EST
  # To: <owner-batmail@v2.listbox.com>
  # Subject: Mail Delivery Problem
  # Mailer: AIRmail [v90_r2.5]
  # Message-ID: <200302161944.08TTIXHa07448@omr-m05.mx.aol.com>
  # Lines: 4
  #
  #
  # Your mail to the following recipients could not be delivered because they are not accepting mail from giltaylor@hawaii.rr.com:
  #         theetopdog
  #

  return unless ($message->head->get("Mailer")||'') =~ /AirMail/i;
  return unless $message->effective_type eq "text/plain";
  return unless $message->bodyhandle->as_string =~ /Your mail to the following recipients could not be delivered because they are not accepting mail from/i;

  my ($host) = $message->head->get("From") =~ /\@(\S+)>/;

  my $rejector;
  my @new_output;
  for (split /\n/, $message->bodyhandle->as_string) {
    if (/because they are not accepting mail from (\S+?):?/i) {
      $rejector = $1;
      push @new_output, $_;
      next;
    }
    if (/^\s*(\S+)\s*$/) {
      my $recipient = $1;
      if ($recipient =~ /\@/) {
        push @new_output, $_;
        next;
      }
      s/^(\s*)(\S+)(\s*)$/$1$2\@$host$3/;
      push @new_output, $_;
      next;
    }
    push @new_output, $_;
    next;
  }

  push @new_output, ("# rewritten by BounceParser: p_aol_senderblock()", "");
  if (my $io = $message->open("w")) {
    $io->print(join "\n", @new_output);
    $io->close;
  }
  return $message;
}

sub p_novell_groupwise_5_2 {
  my $self    = shift;
  my $message = shift;

  # X-Mailer: Novell GroupWise 5.2
  # Date: Thu, 19 Sep 2002 13:52:48 -0700
  # From: Mailer-Daemon@chrismill.com
  # To: listbox+trampoline+260+123494+341495fc@v2.listbox.com
  # Subject: Message status - undeliverable
  # Mime-Version: 1.0
  # Content-Type: multipart/mixed; boundary="=_D68A6C30.E687E8F9"
  # X-Listbox-Reason: lsinger@chrismill.com user unknown
  # Lines: 57
  #
  # --=_D68A6C30.E687E8F9
  # Content-Type: text/plain; charset=US-ASCII
  # Content-Disposition: inline
  #
  # The message that you sent was undeliverable to the following:
  #         lsinger (user not found)
  #
  # Possibly truncated original message follows:
  #
  # --=_D68A6C30.E687E8F9
  # Content-Type: message/rfc822
  #

  return unless ($message->head->get("X-Mailer")||'') =~ /Novell Groupwise/i;
  return unless $message->effective_type eq "multipart/mixed";
  return unless my ($error_part)
    = grep { $_->effective_type eq "text/plain" } $message->parts;

  my ($host) = $message->head->get("From") =~ /\@(\S+)>?/;

  my @new_output;
  for (split /\n/, $error_part->bodyhandle->as_string) {
    if (/^(\s*)(\S+)(\s+\(.*\))$/) {
      my ($space, $recipient, $reason) = ($1, $2, $3);
      if ($recipient =~ /\@/) {
        push @new_output, $_;
        next;
      }
      $_ = join "", $space, "$2\@$host", $reason;
      push @new_output, $_; next;
    }
    push @new_output, $_; next;
  }

  push @new_output,
    ("# rewritten by BounceParser: p_novell_groupwise_5_2()", "");

  if (my $io = $error_part->open("w")) {
    $io->print(join "\n", @new_output);
    $io->close;
  }
  return $message;
}

sub p_aol_bogus_250 {
  my ($self, $message) = @_;

  # the SMTP snapshot shows 550.  the actual Diagnostic-Code shows 250.  what
  # is going on?

  # pennwomen-la@v2.listbox.com/200209/19/1032468845.1444_1.frodo
  # ----- Transcript of session follows -----
  # ... while talking to air-xj03.mail.aol.com.:
  # >>> RCPT To:<robinbw@aol.com>
  # <<< 550 MAILBOX NOT FOUND
  # 550 <robinbw@aol.com>... User unknown
  #
  # --QAM07349.1032468790/rly-xj03.mx.aol.com
  # Content-Type: message/delivery-status
  #
  # Reporting-MTA: dns; rly-xj03.mx.aol.com
  # Arrival-Date: Thu, 19 Sep 2002 16:52:48 -0400 (EDT)
  #
  # Final-Recipient: RFC822; robinbw@aol.com
  # Action: failed
  # Status: 2.0.0
  # Remote-MTA: DNS; air-xj03.mail.aol.com
  # Diagnostic-Code: SMTP; 250 OK
  # Last-Attempt-Date: Thu, 19 Sep 2002 16:53:10 -0400 (EDT)

  return unless $message->head->get("From") =~ /<MAILER-DAEMON\@aol.com>/i;
  return unless $message->effective_type eq "multipart/report";
  my ($plain, $error_part) = $message->parts;

  return unless
    ($error_part->bodyhandle->as_string =~ /Diagnostic-Code: .*250 OK/);

  my %by_email = $self->_analyze_smtp_transcripts($plain->bodyhandle->as_string);

  my (@new_output, $email);
  # rewrite the diagnostic code in the delivery-status part.
  for (split /\n/, $error_part->bodyhandle->as_string) {
    undef $email if /^$/;
    $email = _cleanup_email($1) if (/^Final-Recipient: .*\s(\S+)$/);

    if (/^Diagnostic-Code:/
        and
        exists $by_email{$email}->{smtp_code}
    ) {
      $self->log("cleaning up AOL bogosity: before, $_");
      push @new_output, _construct_diagnostic_code(\%by_email, $email);
      $self->log("cleaning up AOL bogosity:  after, $new_output[-1]");
    }
    push @new_output, $_ and next;
  }

  if (my $io = $error_part->open("w")) {
    $io->print(join "\n", @new_output);
    $io->close;
  }
  return $message;
}

sub _construct_diagnostic_code {
  my %by_email = %{shift()};
  my $email = shift;
  join (" ",
    "Diagnostic-Code: X-BounceParser;",
    ($by_email{$email}->{host} ? "host $by_email{$email}->{host} said:" : ()),
    ($by_email{$email}->{smtp_code}),
    (join ", ", @{ $by_email{$email}->{errors} })
  );
}

sub p_plain_smtp_transcript {
  my ($self, $message) = (shift, shift);

  # sometimes, we have a proper smtp transcript;
  # that means we have enough information to mark the message up into a proper
  # multipart/report!
  #
  # pennwomen-la@v2.listbox.com/200209/19/1032468752.1444_1.frodo
  # The original message was received at Thu, 19 Sep 2002 13:51:36 -0700 (MST)
  # from daemon@localhost
  #
  #    ----- The following addresses had permanent fatal errors -----
  # <friedman@primenet.com>
  #     (expanded from: <friedman@primenet.com>)
  #
  #    ----- Transcript of session follows -----
  # ... while talking to smtp-local.primenet.com.:
  # >>> RCPT To:<friedman@smtp-local.primenet.com>
  # <<< 550 <friedman@smtp-local.primenet.com>... User unknown
  # 550 <friedman@primenet.com>... User unknown
  #    ----- Message header follows -----
  #
  # what we'll do is mark it back up into a proper multipart/report.

  return unless $message->effective_type eq "text/plain";

  return unless $message->bodyhandle->as_string
    =~ /The following addresses had permanent fatal errors/;

  return unless $message->bodyhandle->as_string
    =~ /Transcript of session follows/;

  return unless $message->bodyhandle->as_string =~ /Message .* follows/;

  my ($stuff_before, $stuff_after)
    = split /^.*Message (?:header|body) follows.*$/im,
        $message->bodyhandle->as_string, 2;

  my %by_email = $self->_analyze_smtp_transcripts($stuff_before);

  my @paras = _construct_delivery_status_paras(\%by_email);

  my @new_output;
  my ($reporting_mta) = _cleanup_email($message->head->get("From")) =~ /\@(\S+)/;

  chomp (my $arrival_date = $message->head->get("Date"));

  push @new_output, "Reporting-MTA: $reporting_mta" if $reporting_mta;
  push @new_output, "Arrival-Date: $arrival_date" if $arrival_date;
  push @new_output, "";
  push @new_output, map { @$_, "" } @paras;

  return $self->new_multipart_report(
    $message,
    $stuff_before,
    join("\n", @new_output),
    $stuff_after
  );
}

sub _construct_delivery_status_paras {
  my %by_email = %{shift()};

  my @new_output;

  foreach my $email (sort keys %by_email) {
    # Final-Recipient: RFC822; robinbw@aol.com
    # Action: failed
    # Status: 2.0.0
    # Remote-MTA: DNS; air-xj03.mail.aol.com
    # Diagnostic-Code: SMTP; 250 OK
    # Last-Attempt-Date: Thu, 19 Sep 2002 16:53:10 -0400 (EDT)

    push @new_output, [
      "Final-Recipient: RFC822; $email",
      "Action: failed",
      "Status: 5.0.0",
      ($by_email{$email}->{host} ? ("Remote-MTA: DNS; $by_email{$email}->{host}") : ()),
      _construct_diagnostic_code(\%by_email, $email),
    ];

  }

  return @new_output;
}

sub _analyze_smtp_transcripts {
  my $self = shift;
  my $plain_smtp_transcript = shift;

  my (%by_email, $email, $smtp_code, @error_strings, $host);

  # parse the text part for the actual SMTP transcript
  for (split /\n\n|(?=>>>)/, $plain_smtp_transcript) {
    # $self->log("_analyze_smtp_transcripts: $_") if $DEBUG > 3;

    $email = _cleanup_email($1) if /RCPT TO:\s*(\S+)/im;
    $by_email{$email}->{host} = $host if $email;

    if (/while talking to (\S+)/im) {
      $host = $1;
      $host =~ s/[.:;]+$//g;
    }

    if (/<<< (\d\d\d) (.*)/m) {
      $by_email{$email}->{smtp_code} = $1;
      push @{$by_email{$email}->{errors}}, $2;
    }

    if (/^(\d\d\d)\b.*(<\S+\@\S+>)\.*\s+(.+)/m) {
      $email = _cleanup_email($2);
      $by_email{$email}->{smtp_code} = $1;
      push @{$by_email{$email}->{errors}}, $3;
    }
  }
  delete $by_email{''};
  return %by_email;
}

# ------------------------------------------------------------

sub new_plain_report {
  my ($self, $message, $error_text, $orig_message) = @_;

  $orig_message =~ s/^\s+//;

  my $newmessage = $message->dup();
  $newmessage->make_multipart("plain-report");
  $newmessage->parts([]);
  $newmessage->attach(Type => "text/plain", Data => $error_text);

  my $orig_message_mime = MIME::Entity->build(Type => "multipart/transitory");

  $orig_message_mime->add_part($self->{parser}->parse_data($orig_message));

  $orig_message_mime->head->mime_attr("content-type" => "message/rfc822");
  $newmessage->add_part($orig_message_mime);

  $self->log("created new plain-report message.");

  return $newmessage;
}

# ------------------------------------------------------------

sub new_multipart_report {
  my ($self, $message, $error_text, $delivery_status, $orig_message) = @_;

  $orig_message =~ s/^\s+//;

  my $newmessage = $message->dup();
  $newmessage->make_multipart("report");
  $newmessage->parts([]);
  $newmessage->attach(
    Type => "text/plain",
    Data => $error_text
  );
  $newmessage->attach(
    Type => "message/delivery-status",
    Data => $delivery_status
  );

  my $orig_message_mime
    = MIME::Entity->build(Type => "multipart/transitory", Top => 0);

  $orig_message_mime->add_part($self->{parser}->parse_data($orig_message));

  $orig_message_mime->head->mime_attr("content-type" => "message/rfc822");
  $newmessage->add_part($orig_message_mime);

  $self->log("created new multipart-report message.");

  return $newmessage;
}

# ------------------------------------------------------------

sub _cleanup_email {
  my $email = shift;
  for ($email) {
    chomp;
    s/\(.*\)//;
    s/^To:\s*//i;
    s/[.:;]+$//;
    s/<(.+)>/$1/;
    # IMS hack: c=US;a= ;p=NDC;o=ORANGE;dda:SMTP=slpark@msx.ndc.mc.uci.edu; on
    # Thu, 19 Sep...
    s/.*:SMTP=//;
    s/^\s+//;
    s/\s+$//;
    }
  return $email;
}

sub p_xdelivery_status {
  my ($self, $message) = @_;

  # This seems to be caused by something called "XWall v3.31", which
  # (according to Google) is a "firewall that protects your Exchange
  # server from viruses, spam mail and dangerous attachments".  Shame it
  # doesn't protect the rest of the world from gratuitously broken MIME
  # types.

  for ($message->parts_DFS) {
    $_->effective_type('message/delivery-status')
      if $_->effective_type eq 'message/xdelivery-status';
  }
}

sub _first_non_multi_part {
  my ($entity) = @_;

  my $part = $entity;
  $part = $part->parts(0) or return while $part->is_multipart;
  return $part;
}

sub _position_before {
  my ($pos_a, $pos_b) = @_;
  return 1 if defined($pos_a) && (!defined($pos_b) || $pos_a < $pos_b);
  return;
}

# Return the position in $string at which $regex first matches, or undef if
# no match.
sub _match_position {
  my ($string, $regex) = @_;
  return $string =~ $regex ? $-[0] : undef;
}

1;
