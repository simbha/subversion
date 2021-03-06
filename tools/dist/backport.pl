#!/usr/bin/perl
use warnings;
use strict;
use feature qw/switch say/;

# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

use Carp qw/croak confess carp cluck/;
use Digest ();
use Term::ReadKey qw/ReadMode ReadKey/;
use File::Basename qw/basename dirname/;
use File::Copy qw/copy move/;
use File::Temp qw/tempfile/;
use POSIX qw/ctermid strftime isprint isspace/;
use Text::Wrap qw/wrap/;
use Tie::File ();

############### Start of reading values from environment ###############

# Programs we use.
#
# TODO: document which are interpreted by sh and which should point to binary.
my $SVNAUTH = $ENV{SVNAUTH} // 'svnauth'; # optional dependency
my $SVN = $ENV{SVN} || 'svn'; # passed unquoted to sh
my $SHELL = $ENV{SHELL} // '/bin/sh';
my $VIM = 'vim';
my $EDITOR = $ENV{SVN_EDITOR} // $ENV{VISUAL} // $ENV{EDITOR} // 'ed';
my $PAGER = $ENV{PAGER} // 'less' // 'cat';

# Mode flags.
#    svn-role:      YES=1 MAY_COMMIT=1      (plus '--renormalize')
#    conflicts-bot: YES=1 MAY_COMMIT=0
#    interactive:   YES=0 MAY_COMMIT=0      (default)
my $YES = ($ENV{YES} // "0") =~ /^(1|yes|true)$/i; # batch mode: eliminate prompts, add sleeps
my $MAY_COMMIT = ($ENV{MAY_COMMIT} // "false") =~ /^(1|yes|true)$/i;

# Other knobs.
my $VERBOSE = 0;
my $DEBUG = (exists $ENV{DEBUG}); # 'set -x', etc

# Force all these knobs to be usable via @sh.
my @sh = qw/false true/;
die if grep { ($sh[$_] eq 'true') != !!$_ } $DEBUG, $MAY_COMMIT, $VERBOSE, $YES;

# Username for entering votes.
my $SVN_A_O_REALM = '<https://svn.apache.org:443> ASF Committers';            
my ($AVAILID) = $ENV{AVAILID} // do {
  local $_ = `$SVNAUTH list 2>/dev/null`;
  ($? == 0 && /Auth.*realm: \Q$SVN_A_O_REALM\E\nUsername: (.*)/) ? $1 : undef
} // do {
  local $/; # slurp mode
  my $filename = Digest->new("MD5")->add($SVN_A_O_REALM)->hexdigest;
  `cat $ENV{HOME}/.subversion/auth/svn.simple/$filename`
  =~ /K 8\nusername\nV \d+\n(.*)/ and $1 or undef
}
// warn "Username for commits (of votes/merges) not found";

############## End of reading values from the environment ##############

# Constants.
my $STATUS = './STATUS';
my $STATEFILE = './.backports1';
my $BRANCHES = '^/subversion/branches';
$ENV{LC_ALL} = "C";  # since we parse 'svn info' output and use isprint()

# Globals.
my %ERRORS = ();
my $MERGED_SOMETHING = 0;
my $SVNq;

# Derived values.
my $SVNvsn = do {
  my ($major, $minor, $patch) = `$SVN --version -q` =~ /^(\d+)\.(\d+)\.(\d+)/;
  1e6*$major + 1e3*$minor + $patch;
};
$SVN .= " --non-interactive" if $YES or not defined ctermid;
$SVNq = "$SVN -q ";
$SVNq =~ s/-q// if $DEBUG;


sub backport_usage {
  my $basename = basename $0;
  print <<EOF;
backport.pl: a tool for reviewing, merging, and voting on STATUS entries.

Normally, invoke this with CWD being the root of the stable branch (e.g.,
1.8.x):

    Usage: test -e \$d/STATUS && cd \$d && \\
           backport.pl [PATTERN]
    (where \$d is a working copy of branches/1.8.x)

Alternatively, invoke this via a symlink named "b" placed at the same directory
as the STATUS file, in which case the CWD doesn't matter (the script will cd):

    Usage: ln -s /path/to/backport.pl \$d/b && \\
           \$d/b [PATTERN]
    (where \$d is a working copy of branches/1.8.x)

In either case, the ./STATUS file should be at HEAD.  If it has local mods,
they will be preserved through 'revert' operations but included in 'commit'
operations.

If PATTERN is provided, only entries which match PATTERN are considered.  The
sense of "match" is either substring (fgrep) or Perl regexp (with /msi).

In interactive mode (the default), you will be prompted once per STATUS entry.
At a prompt, you have the following options:

y:   Run a merge.  It will not be committed.
     WARNING: This will run 'update' and 'revert -R ./'.
l:   Show logs for the entries being nominated.
v:   Show the full entry (the prompt only shows an abridged version).
q:   Quit the "for each nomination" loop.
±1:  Enter a +1 or -1 vote
     You will be prompted to commit your vote at the end.
±0:  Enter a +0 or -0 vote
     You will be prompted to commit your vote at the end.
a:   Move the entry to the "Approved changes" section.
     When both approving and voting on an entry, approve first: for example,
     to enter a third +1 vote, type "a" "+" "1".
e:   Edit the entry in $EDITOR.
     You will be prompted to commit your edits at the end.
N:   Move to the next entry.  Cache the entry in '$STATEFILE' and do not
     prompt for it again (even across runs) until it is changed.
 :   Move to the next entry, without adding the current one to the cache.
     (That's a space character, ASCII 0x20.)

After running a merge, you have the following options:

y:   Open a shell.
d:   View a diff.
N:   Move to the next entry.

There is also a batch mode (normally used only by cron jobs and buildbot tasks,
rather than interactively): when \$YES and \$MAY_COMMIT are defined to '1' in
the environment, this script will iterate the "Approved:" section, and merge
and commit each entry therein.  If only \$YES is defined, the script will
merge every nomination (including unapproved and vetoed ones), and complain
to stderr if it notices any conflicts.

The 'svn' binary defined by the environment variable \$SVN, or otherwise the
'svn' found in \$PATH, will be used to manage the working copy.
EOF
}

sub nominate_usage {
  my $basename = basename $0;
  print <<EOF;
nominate.pl: a tool for adding entries to STATUS.

Usage: $0 "foo r42 bar r43 qux 45." "\$Some_justification"

Will add:
 * r42, r43, r45
   (log message of r42)
   Justification:
     \$Some_justification
   Votes:
     +1: $AVAILID
to STATUS.  Backport branches are detected automatically.

The STATUS file in the current directory is used (unless argv[0] is "n", in
which case the STATUS file in the directory of argv[0] is used; the intent
is to create a symlink named "n" in the branch wc root).

EOF
# TODO: Optionally add a "Notes" section.
# TODO: Look for backport branches named after issues.
# TODO: Do a dry-run merge on added entries.
# TODO: Do a dry-run merge on interactively-edited entries in backport.pl
}

sub digest_string {
  Digest->new("MD5")->add(@_)->hexdigest
}

sub digest_entry($) {
  # Canonicalize the number of trailing EOLs to two.  This matters when there's
  # on empty line after the last entry in Approved, for example.
  local $_ = shift;
  s/\n*\z// and $_ .= "\n\n";
  digest_string($_)
}

sub prompt {
  print $_[0]; shift;
  my %args = @_;
  my $getchar = sub {
    my $answer;
    do {
      ReadMode 'cbreak';
      $answer = (ReadKey 0);
      ReadMode 'normal';
      die if $@ or not defined $answer;
      # Swallow terminal escape codes (e.g., arrow keys).
      unless (isprint $answer or isspace $answer) {
        $answer = (ReadKey -1) while defined $answer;
        # TODO: provide an indication that the keystroke was sensed and ignored.
      }
    } until defined $answer and (isprint $answer or isspace $answer);
    print $answer;
    return $answer;
  };

  die "$0: called prompt() in non-interactive mode!" if $YES;
  my $answer = $getchar->();
  $answer .= $getchar->() if exists $args{extra} and $answer =~ $args{extra};
  say "" unless $args{dontprint};
  return $args{verbose}
         ? $answer
         : ($answer =~ /^y/i) ? 1 : 0;
}

# Bourne-escape a string.
# Example:
#     >>> shell_escape(q[foo'bar]) eq q['foo'\''bar']
#     True
sub shell_escape {
  map {
    local $_ = $_; # the LHS $_ is mutable; the RHS $_ may not be.
    s/\x27/'\\\x27'/g;
    "'$_'"
  } @_
}

sub shell_safe_path_or_url($) {
  local $_ = shift;
  return m{^[A-Za-z0-9._:+/-]+$} and !/^-|^[+]/;
}
  
# Shell-safety-validating wrapper for File::Temp::tempfile
sub my_tempfile {
  my ($fh, $fn) = tempfile();
  croak "Tempfile name '$fn' not shell-safe; aborting"
        unless shell_safe_path_or_url $fn;
  return ($fh, $fn);
}


sub merge {
  my %entry = @_;

  my ($logmsg_fh, $logmsg_filename) = my_tempfile();
  my (@mergeargs);

  my $shell_escaped_branch = shell_escape($entry{branch})
    if defined($entry{branch});

  if ($entry{branch}) {
    if ($SVNvsn >= 1_008_000) {
      @mergeargs = shell_escape "$BRANCHES/$entry{branch}";
      say $logmsg_fh "Merge $entry{header}:";
    } else {
      @mergeargs = shell_escape qw/--reintegrate/, "$BRANCHES/$entry{branch}";
      say $logmsg_fh "Reintegrate $entry{header}:";
    }
    say $logmsg_fh "";
  } elsif (@{$entry{revisions}}) {
    @mergeargs = shell_escape(
      ($entry{accept} ? "--accept=$entry{accept}" : ()),
      (map { "-c$_" } @{$entry{revisions}}),
      '--',
      '^/subversion/trunk',
    );
    say $logmsg_fh
      "Merge $entry{header} from trunk",
      $entry{accept} ? ", with --accept=$entry{accept}" : "",
      ":";
    say $logmsg_fh "";
  } else {
    die "Don't know how to call $entry{header}";
  }
  say $logmsg_fh $_ for @{$entry{entry}};
  close $logmsg_fh or die "Can't close $logmsg_filename: $!";

  my $reintegrated_word = ($SVNvsn >= 1_008_000) ? "merged" : "reintegrated";
  my $script = <<"EOF";
#!/bin/sh
set -e
if $sh[$DEBUG]; then
  set -x
fi
$SVNq up
$SVNq merge @mergeargs
if [ "`$SVN status -q | wc -l`" -eq 1 ]; then
  if [ -n "`$SVN diff | perl -lne 'print if s/^(Added|Deleted|Modified): //' | grep -vx svn:mergeinfo`" ]; then
    # This check detects STATUS entries that name non-^/subversion/ revnums.
    # ### Q: What if we actually commit a mergeinfo fix to trunk and then want
    # ###    to backport it?
    # ### A: We don't merge it using the script.
    echo "Bogus merge: includes only svn:mergeinfo changes!" >&2
    exit 2
  fi
fi
if $sh[$MAY_COMMIT]; then
  # Remove the approved entry.  The sentinel guarantees the right number of blank
  # lines is removed, which prevents spurious '--renormalize' commits tomorrow.
  echo "sentinel" >> $STATUS
  $VIM -e -s -n -N -i NONE -u NONE -c ':0normal! $entry{parno}\x{7d}kdap' -c wq $STATUS
  $VIM -e -s -n -N -i NONE -u NONE -c '\$d' -c wq $STATUS
  $SVNq commit -F $logmsg_filename
elif ! $sh[$YES]; then
  echo "Would have committed:"
  echo '[[['
  $SVN status -q
  echo 'M       STATUS (not shown in the diff)'
  cat $logmsg_filename
  echo ']]]'
fi
EOF

  $script .= <<"EOF" if $entry{branch};
reinteg_rev=\`$SVN info $STATUS | sed -ne 's/Last Changed Rev: //p'\`
if $sh[$MAY_COMMIT]; then
  # Sleep to avoid out-of-order commit notifications
  if $sh[$YES]; then sleep 15; fi
  $SVNq rm $BRANCHES/$shell_escaped_branch -m "Remove the '"$shell_escaped_branch"' branch, $reintegrated_word in r\$reinteg_rev."
  if $sh[$YES]; then sleep 1; fi
elif ! $sh[$YES]; then
  echo "Would remove $reintegrated_word '"$shell_escaped_branch"' branch"
fi
EOF

  # Include the time so it's easier to find the interesting backups.
  my $backupfile = strftime "backport_pl.%Y%m%d-%H%M%S.$$.tmp", localtime;
  die if -s $backupfile;
  system("$SVN diff > $backupfile") == 0
    or die "Saving a backup diff ($backupfile) failed ($?): $!";
  if (-z $backupfile) {
    unlink $backupfile;
  } else {
    warn "Local mods saved to '$backupfile'\n";
  }

  # If $MAY_COMMIT, then $script will edit STATUS anyway.
  revert(verbose => 0, discard_STATUS => $MAY_COMMIT);

  $MERGED_SOMETHING++;
  open SHELL, '|-', qw#/bin/sh# or die "$! (in '$entry{header}')";
  print SHELL $script;
  close SHELL or warn "$0: sh($?): $! (in '$entry{header}')";
  $ERRORS{$entry{id}} = [\%entry, "sh($?): $!"] if $?;

  unlink $logmsg_filename unless $? or $!;
}

# Input formats:
#    "1.8.x-r42",
#    "branches/1.8.x-r42",
#    "branches/1.8.x-r42/",
#    "subversion/branches/1.8.x-r42",
#    "subversion/branches/1.8.x-r42/",
#    "^/subversion/branches/1.8.x-r42",
#    "^/subversion/branches/1.8.x-r42/",
# Return value:
#    "1.8.x-r42"
# Works for any branch name that doesn't include slashes.
sub sanitize_branch {
  local $_ = shift;
  s/^\s*//;
  s/\s*$//;
  s#/*$##;
  s#.*/##;
  return $_;
}

sub logsummarysummary {
  my $entry = shift;
  join "",
    $entry->{logsummary}->[0], ('[...]' x (0 < $#{$entry->{logsummary}}))
}

# TODO: may need to parse other headers too?
sub parse_entry {
  my $raw = shift;
  my $parno = shift;
  my @lines = @_;
  my $depends;
  my $accept;
  my (@revisions, @logsummary, $branch, @votes);
  # @lines = @_;

  # strip spaces to match up with the indention
  $_[0] =~ s/^( *)\* //;
  my $indentation = ' ' x (length($1) + 2);
  s/^$indentation// for @_;

  # Ignore trailing spaces: it is not significant on any field, and makes the
  # regexes simpler.
  s/\s*$// for @_;

  # revisions
  $branch = sanitize_branch $1
    and shift
    if $_[0] =~ /^(\S*) branch$/ or $_[0] =~ m#branches/(\S+)#;
  while ($_[0] =~ /^(?:r?\d+[,; ]*)+$/) {
    push @revisions, ($_[0] =~ /(\d+)/g);
    shift;
  }

  # summary
  do {
    push @logsummary, shift
  } until $_[0] =~ /^\s*[][\w]+:/ or not defined $_[0];

  # votes
  unshift @votes, pop until $_[-1] =~ /^\s*Votes:/ or not defined $_[-1];
  pop;

  # depends, branch, notes
  # Ignored headers: Changes[*]
  while (@_) {
    given (shift) {
      when (/^Depends:/) {
        $depends++;
      }
      if (s/^Branch:\s*//) {
        $branch = sanitize_branch ($_ || shift || die "Branch header found without value");
      }
      if (s/^Notes:\s*//) {
        my $notes = $_;
        $notes .= shift while @_ and $_[0] !~ /^\w/;
        my %accepts = map { $_ => 1 } ($notes =~ /--accept[ =]([a-z-]+)/g);
        given (scalar keys %accepts) {
          when (0) { } 
          when (1) { $accept = [keys %accepts]->[0]; } 
          default  {
            warn "Too many --accept values at '",
                 logsummarysummary({ logsummary => [@logsummary] }),
                 "'";
          }
        }
      }
    }
  }

  # Compute a header.
  my ($header, $id);
  if ($branch) {
    $header = "the $branch branch";
    $id = $branch;
  } elsif (@revisions == 1) {
    $header = "r$revisions[0]";
    $id = "r$revisions[0]";
  } elsif (@revisions) {
    $header = "the r$revisions[0] group";
    $id = "r$revisions[0]";
  } else {
    die "Entry '$raw' has neither revisions nor branch";
  }
  my $header_start = ($header =~ /^the/ ? ucfirst($header) : $header);

  warn "Entry has both branch '$branch' and --accept=$accept specified\n"
    if $branch and $accept;

  return (
    revisions => [@revisions],
    logsummary => [@logsummary],
    branch => $branch,
    header => $header,
    header_start => $header_start,
    depends => $depends,
    id => $id,
    votes => [@votes],
    entry => [@lines],
    accept => $accept,
    raw => $raw,
    digest => digest_entry($raw),
    parno => $parno, # $. from backport_main()
  );
}

sub edit_string {
  # Edits $_[0] in an editor.
  # $_[1] is used in error messages.
  die "$0: called edit_string() in non-interactive mode!" if $YES;
  my $string = shift;
  my $name = shift;
  my %args = @_;
  my $trailing_eol = $args{trailing_eol};
  my ($fh, $fn) = my_tempfile();
  print $fh $string;
  $fh->flush or die $!;
  system("$EDITOR -- $fn") == 0
    or warn "\$EDITOR failed editing $name: $! ($?); "
           ."edit results ($fn) ignored.";
  my $rv = `cat $fn`;
  $rv =~ s/\n*\z// and $rv .= ("\n" x $trailing_eol) if defined $trailing_eol;
  $rv;
}

sub vote {
  my ($state, $approved, $votes) = @_;
  # TODO: use votesarray instead of votescheck
  my (%approvedcheck, %votescheck);
  my $raw_approved = "";
  my @votesarray;
  return unless %$approved or %$votes;

  my $had_empty_line;

  $. = 0;
  open STATUS, "<", $STATUS;
  open VOTES, ">", "$STATUS.$$.tmp";
  while (<STATUS>) {
    $had_empty_line = /\n\n\z/;
    my $key = digest_entry $_;

    $approvedcheck{$key}++ if exists $approved->{$key};
    $votescheck{$key}++ if exists $votes->{$key};

    unless (exists $votes->{$key} or exists $approved->{$key}) {
      print VOTES;
      next;
    }

    unless (exists $votes->{$key}) {
      push @votesarray, {
        entry => $approved->{$key},
        approval => 1,
        digest => $key,
      };
      $raw_approved .= $_;
      next;
    }

    # We have a vote, and potentially an approval.

    my ($vote, $entry) = @{$votes->{$key}};
    push @votesarray, {
      entry => $entry,
      vote => $vote,
      approval => (exists $approved->{$key}),
      digest => $key,
    };

    if ($vote eq 'edit') {
      local $_ = $entry->{raw};
      $votesarray[-1]->{digest} = digest_entry $_;
      (exists $approved->{$key}) ? ($raw_approved .= $_) : (print VOTES);
      next;
    }
    
    s/^(\s*\Q$vote\E:.*)/"$1, $AVAILID"/me
    or s/(.*\w.*?\n)/"$1     $vote: $AVAILID\n"/se;
    $_ = edit_string $_, $entry->{header}, trailing_eol => 2
        if $vote ne '+1';
    $votesarray[-1]->{digest} = digest_entry $_;
    (exists $approved->{$key}) ? ($raw_approved .= $_) : (print VOTES);
  }
  close STATUS;
  print VOTES "\n" if $raw_approved and !$had_empty_line;
  print VOTES $raw_approved;
  close VOTES;
  warn "Some vote chunks weren't found: ",
    join ',',
    map $votes->{$_}->[1]->{id},
    grep { !$votescheck{$_} } keys %$votes
    if scalar(keys %$votes) != scalar(keys %votescheck);
  warn "Some approval chunks weren't found: ",
    join ',',
    map $approved->{$_}->{id},
    grep { !$approvedcheck{$_} } keys %$approved
    if scalar(keys %$approved) != scalar(keys %approvedcheck);
  prompt "Press the 'any' key to continue...\n", dontprint => 1
    if scalar(keys %$approved) != scalar(keys %approvedcheck) 
    or scalar(keys %$votes) != scalar(keys %votescheck);
  move "$STATUS.$$.tmp", $STATUS;

  my $logmsg = do {
    my @sentences = map {
       my $words_vote = ", approving" x $_->{approval};
       my $words_edit = " and approve" x $_->{approval};
       exists $_->{vote}
       ? (
         ( $_->{vote} eq 'edit'
           ? "Edit$words_edit the $_->{entry}->{id} entry"
           : "Vote $_->{vote} on $_->{entry}->{header}$words_vote"
         )
         . "."
         )
      : # exists only in $approved
        "Approve $_->{entry}->{header}."
      } @votesarray;
    (@sentences == 1)
    ? $sentences[0]
    : "* STATUS:\n" . join "", map "  $_\n", @sentences;
  };

  system "$SVN diff -- $STATUS";
  printf "[[[\n%s%s]]]\n", $logmsg, ("\n" x ($logmsg !~ /\n\z/));
  if (prompt "Commit these votes? ") {
    my ($logmsg_fh, $logmsg_filename) = my_tempfile();
    print $logmsg_fh $logmsg;
    close $logmsg_fh;
    system("$SVN commit -F $logmsg_filename -- $STATUS") == 0
        or warn("Committing the votes failed($?): $!") and return;
    unlink $logmsg_filename;

    # Add to state votes that aren't '+0' or 'edit'
    $state->{$_->{digest}}++ for grep
                                   +{ qw/-1 t -0 t +1 t/ }->{$_->{vote}},
                                 @votesarray;
  }
}

sub check_local_mods_to_STATUS {
  if (`$SVN status -q $STATUS`) {
    die  "Local mods to STATUS file $STATUS" if $YES;
    warn "Local mods to STATUS file $STATUS";
    system "$SVN diff -- $STATUS";
    prompt "Press the 'any' key to continue...\n", dontprint => 1;
    return 1;
  }
  return 0;
}

sub renormalize_STATUS {
  my $vimscript = <<'EOVIM';
:"" Strip trailing whitespace before entries and section headers, but not
:"" inside entries (e.g., multi-paragraph Notes: fields).
:""
:"" Since an entry is always followed by another entry, section header, or EOF,
:"" there is no need to separately strip trailing whitespace from lines following
:"" entries.
:%s/\v\s+\n(\s*\n)*\ze(\s*[*]|\w)/\r\r/g

:"" Ensure there is exactly one blank line around each entry and header.
:""
:"" First, inject a new empty line above and below each entry and header; then,
:"" squeeze runs of empty lines together.
:0/^=/,$ g/^ *[*]/normal! O
:g/^=/normal! o
:g/^=/-normal! O
:
:%s/\n\n\n\+/\r\r/g

:"" Save.
:wq
EOVIM
  open VIM, '|-', $VIM, qw/-e -s -n -N -i NONE -u NONE --/, $STATUS
    or die "Can't renormalize STATUS: $!";
  print VIM $vimscript;
  close VIM or warn "$0: renormalize_STATUS failed ($?): $!)";

  system("$SVN commit -m '* STATUS: Whitespace changes only.' -- $STATUS") == 0
    or die "$0: Can't renormalize STATUS ($?): $!"
    if $MAY_COMMIT;
}

sub revert {
  my %args = @_;
  die "Bug: \$args{verbose} undefined" unless exists $args{verbose};
  die "Bug: unknown argument" if grep !/^(?:verbose|discard_STATUS)$/, keys %args;

  copy $STATUS, "$STATUS.$$.tmp"        unless $args{discard_STATUS};
  system("$SVN revert -q $STATUS") == 0
    or die "revert failed ($?): $!";
  system("$SVN revert -R ./" . (" -q" x !$args{verbose})) == 0
    or die "revert failed ($?): $!";
  move "$STATUS.$$.tmp", $STATUS        unless $args{discard_STATUS};
  $MERGED_SOMETHING = 0;
}

sub maybe_revert {
  # This is both a SIGINT handler, and the tail end of main() in normal runs.
  # @_ is 'INT' in the former case and () in the latter.
  delete $SIG{INT} unless @_;
  revert verbose => 1 if !$YES and $MERGED_SOMETHING and prompt 'Revert? ';
  (@_ ? exit : return);
}

sub signal_handler {
  my $sig = shift;

  # Clean up after prompt()
  ReadMode 'normal';

  # Fall back to default action
  delete $SIG{$sig};
  kill $sig, $$;
}

sub warning_summary {
  return unless %ERRORS;

  warn "Warning summary\n";
  warn "===============\n";
  warn "\n";
  for my $id (keys %ERRORS) {
    my $title = logsummarysummary $ERRORS{$id}->[0];
    warn "$id ($title): $ERRORS{$id}->[1]\n";
  }
}

sub read_state {
  # die "$0: called read_state() in non-interactive mode!" if $YES;

  open my $fh, '<', $STATEFILE or do {
    return {} if $!{ENOENT};
    die "Can't read statefile: $!";
  };

  my %rv;
  while (<$fh>) {
    chomp;
    $rv{$_}++;
  }
  return \%rv;
}

sub write_state {
  my $state = shift;
  open STATE, '>', $STATEFILE or warn("Can't write state: $!"), return;
  say STATE for keys %$state;
  close STATE;
}

sub exit_stage_left {
  my $state = shift;
  maybe_revert;
  warning_summary if $YES;
  vote $state, @_;
  write_state $state;
  exit scalar keys %ERRORS;
}

sub handle_entry {
  my $in_approved = shift;
  my $approved = shift;
  my $votes = shift;
  my $state = shift;
  my $raw = shift;
  my $parno = shift;
  my $skip = shift;
  my %entry = parse_entry $raw, $parno, @_;
  my @vetoes = grep /^\s*-1:/, @{$entry{votes}};

  my $match = defined($skip) ? ($raw =~ /\Q$skip\E/ or $raw =~ /$skip/msi) : 0
              unless $YES;

  if ($YES) {
    # Run a merge if:
    unless (@vetoes) {
      if ($MAY_COMMIT and $in_approved) {
        # svn-role mode
        merge %entry;
      } elsif (!$MAY_COMMIT) {
        # Scan-for-conflicts mode
        merge %entry;

        my $output = `$SVN status`;

        # Pre-1.6 svn's don't have the 7th column, so fake it.
        $output =~ s/^(......)/$1 /mg if $SVNvsn < 1_006_000;

        my (@conflicts) = ($output =~ m#^(?:C......|.C.....|......C)\s(.*)#mg);
        if (@conflicts and !$entry{depends}) {
          $ERRORS{$entry{id}} //= [\%entry,
                                   sprintf "Conflicts on %s%s%s",
                                     '[' x !!$#conflicts,
                                     (join ', ',
                                      map { basename $_ }
                                      @conflicts),
                                     ']' x !!$#conflicts,
                                  ];
          say STDERR "Conflicts merging $entry{header}!";
          say STDERR "";
          say STDERR $output;
          system "$SVN diff -- " . join ' ', shell_escape @conflicts;
        } elsif (!@conflicts and $entry{depends}) {
          # Not a warning since svn-role may commit the dependency without
          # also committing the dependent in the same pass.
          print "No conflicts merging $entry{header}, but conflicts were "
              ."expected ('Depends:' header set)\n";
        } elsif (@conflicts) {
          say "Conflicts found merging $entry{header}, as expected.";
        }
        revert verbose => 0;
      }
    }
  } elsif (defined($skip) ? not $match : $state->{$entry{digest}}) {
    print "\n\n";
    my $reason = defined($skip) ? "doesn't match pattern"
                                : "remove $STATEFILE to reset";
    say "Skipping $entry{header} ($reason):";
    say logsummarysummary \%entry;
  } elsif ($match or not defined $skip) {
    # This loop is just a hack because 'goto' panics.  The goto should be where
    # the "next PROMPT;" is; there's a "last;" at the end of the loop body.
    PROMPT: while (1) {
    say "";
    say "\n>>> $entry{header_start}:";
    say join ", ", map { "r$_" } @{$entry{revisions}} if @{$entry{revisions}};
    say "$BRANCHES/$entry{branch}" if $entry{branch};
    say "--accept=$entry{accept}" if $entry{accept};
    say "";
    say for @{$entry{logsummary}};
    say "";
    say for @{$entry{votes}};
    say "";
    say "Vetoes found!" if @vetoes;

    # See above for why the while(1).
    QUESTION: while (1) {
    my $key = $entry{digest};
    given (prompt 'Run a merge? [y,l,v,±1,±0,q,e,a, ,N] ',
                   verbose => 1, extra => qr/[+-]/) {
      when (/^y/i) {
        merge %entry;
        while (1) { 
          given (prompt "Shall I open a subshell? [ydN] ", verbose => 1) {
            when (/^y/i) {
              system($SHELL) == 0
                or warn "Creating an interactive subshell failed ($?): $!"
            }
            when (/^d/) {
              system("$SVN diff | $PAGER") == 0
                or warn "diff failed ($?): $!";
              next;
            }
            when (/^N/i) {
              # fall through.
            }
            default {
              next;
            }
          }
          revert verbose => 1;
          next PROMPT;
        }
        # NOTREACHED
      }
      when (/^l/i) {
        if ($entry{branch}) {
            system "$SVN log --stop-on-copy -v -g -r 0:HEAD -- "
                   .shell_escape("$BRANCHES/$entry{branch}")." "
                   ."| $PAGER";
        } elsif (@{$entry{revisions}}) {
            system "$SVN log ".(join ' ', map { "-r$_" } @{$entry{revisions}})
                   ." -- ^/subversion | $PAGER";
        } else {
            die "Assertion failed: entry has neither branch nor revisions:\n",
                '[[[', (join ';;', %entry), ']]]';
        }
        next PROMPT;
      }
      when (/^v/i) {
        say "";
        say for @{$entry{entry}};
        say "";
        next QUESTION;
      }
      when (/^q/i) {
        exit_stage_left $state, $approved, $votes;
      }
      when (/^a/i) {
        $approved->{$key} = \%entry;
        next PROMPT;
      }
      when (/^([+-][01])\s*$/i) {
        $votes->{$key} = [$1, \%entry];
        say "Your '$1' vote has been recorded." if $VERBOSE;
        last PROMPT;
      }
      when (/^e/i) {
        my $original = $entry{raw};
        $entry{raw} = edit_string $entry{raw}, $entry{header},
                        trailing_eol => 2;
        # TODO: parse the edited entry (empty lines, logsummary+votes, etc.)
        $votes->{$key} = ['edit', \%entry] # marker for the 2nd pass
            if $original ne $entry{raw};
        last PROMPT;
      }
      when (/^N/i) {
        $state->{$entry{digest}}++;
        last PROMPT;
      }
      when (/^\x20/) {
        last PROMPT; # Fall off the end of the given/when block.
      }
      default {
        say "Please use one of the options in brackets (q to quit)!";
        next QUESTION;
      }
    }
    last; } # QUESTION
    last; } # PROMPT
  } else {
    # NOTREACHED
    die "Unreachable code reached.";
  }

  # TODO: merge() changes ./STATUS, which we're reading below, but
  #       on my system the loop in main() doesn't seem to care.

  1;
}


sub backport_main {
  my %approved;
  my %votes;
  my $state = read_state;
  my $renormalize;

  if (@ARGV && $ARGV[0] eq '--renormalize') {
    $renormalize = 1;
    shift;
  }

  backport_usage, exit 0 if @ARGV > ($YES ? 0 : 1) or grep /^--help$/, @ARGV;
  backport_usage, exit 0 if grep /^(?:-h|-\?|--help|help)$/, @ARGV;
  my $skip = shift; # maybe undef
  # assert not defined $skip if $YES;

  open STATUS, "<", $STATUS or (backport_usage, exit 1);

  # Because we use the ':normal' command in Vim...
  die "A vim with the +ex_extra feature is required for --renormalize and "
      ."\$MAY_COMMIT modes"
      if ($renormalize or $MAY_COMMIT) and `${VIM} --version` !~ /[+]ex_extra/;

  # ### TODO: need to run 'revert' here
  # ### TODO: both here and in merge(), unlink files that previous merges added
  # When running from cron, there shouldn't be local mods.  (For interactive
  # usage, we preserve local mods to STATUS.)
  system("$SVN info $STATUS >/dev/null") == 0
    or die "$0: svn error; point \$SVN to an appropriate binary";

  check_local_mods_to_STATUS;
  renormalize_STATUS if $renormalize;

  # Skip most of the file
  $/ = ""; # paragraph mode
  while (<STATUS>) {
    last if /^Status of \d+\.\d+/;
  }

  $SIG{INT} = \&maybe_revert unless $YES;
  $SIG{TERM} = \&signal_handler unless $YES;

  my $in_approved = 0;
  while (<STATUS>) {
    my $lines = $_;
    my @lines = split /\n/;

    given ($lines[0]) {
      # Section header
      when (/^[A-Z].*:$/i) {
        say "\n\n=== $lines[0]" unless $YES;
        $in_approved = $lines[0] =~ /^Approved changes/;
      }
      # Comment
      when (/^[#\x5b]/i) {
        next;
      }
      # Separator after section header
      when (/^=+$/i) {
        break;
      }
      # Backport entry?
      when (/^ *\*/) {
        warn "Too many bullets in $lines[0]" and next
          if grep /^ *\*/, @lines[1..$#lines];
        handle_entry $in_approved, \%approved, \%votes, $state, $lines, $.,
                     $skip,
                     @lines;
      }
      default {
        warn "Unknown entry '$lines[0]'";
      }
    }
  }

  exit_stage_left $state, \%approved, \%votes;
}

sub nominate_main {
  my $had_local_mods;

  local $Text::Wrap::columns = 79;

  $had_local_mods = check_local_mods_to_STATUS;

  # Argument parsing.
  nominate_usage, exit 0 if @ARGV != 2;
  my (@revnums) = (+shift) =~ /(\d+)/g;
  my $justification = shift;

  @revnums = sort { $a <=> $b } keys %{{ map { $_ => 1 } @revnums }};
  die "No revision numbers specified" unless @revnums;

  # Determine whether a backport branch exists
  my ($URL) = `$SVN info` =~ /^URL: (.*)$/m;
  die "Can't retrieve URL of cwd" unless $URL;

  die unless shell_safe_path_or_url $URL;
  system "$SVN info -- $URL-r$revnums[0] 2>/dev/null";
  my $branch = ($? == 0) ? basename("$URL-r$revnums[0]") : undef;

  # Construct entry.
  my $logmsg = `$SVN propget --revprop -r $revnums[0] --strict svn:log '^/'`;
  die "Can't fetch log message of r$revnums[0]: $!" unless $logmsg;
  
  unless ($logmsg =~ s/^(.*?)\n\n.*/$1/s) {
    # "* file\n  (symbol): Log message."

    # Strip before and after the first symbol's log message.
    $logmsg =~ s/^.*?: //s;
    $logmsg =~ s/^  \x28.*//ms;

    # Undo line wrapping.  (We'll re-do it later.)
    $logmsg =~ s/\s*\n\s+/ /g;
  }

  my @lines;
  warn "Wrapping [$logmsg]\n";
  push @lines, wrap " * ", ' 'x3, join ', ', map "r$_", @revnums;
  push @lines, wrap ' 'x3, ' 'x3, split /\n/, $logmsg;
  push @lines, "   Justification:";
  push @lines, wrap ' 'x5, ' 'x5, $justification;
  push @lines, "   Branch: $branch" if defined $branch;
  push @lines, "   Votes:";
  push @lines, "     +1: $AVAILID";
  push @lines, "";
  my $raw = join "", map "$_\n", @lines;

  # Open the file in line-mode (not paragraph-mode).
  my @STATUS;
  tie @STATUS, "Tie::File", $STATUS, recsep => "\n";
  my ($index) = grep { $STATUS[$_] =~ /^Veto/ } (0..$#STATUS);
  die "Couldn't find where to add an entry" unless $index;

  # Add an empty line if needed.
  if ($STATUS[$index-1] =~ /\S/) {
    splice @STATUS, $index, 0, "";
    $index++;
  }

  # Add the entry.
  splice @STATUS, $index, 0, @lines;

  # Save.
  untie @STATUS;

  # Done!
  system "$SVN diff -- $STATUS";
  if (prompt "Commit this nomination? ") {
    system "$SVN commit -m 'Nominate r$revnums[0].' -- $STATUS";
    exit $?;
  }
  elsif (!$had_local_mods or prompt "Revert STATUS (destroying local mods)? ") {
    # TODO: we could be smarter and just un-splice the lines we'd added.
    system "$SVN revert -- $STATUS";
    exit $?;
  }

  exit 0;
}

# Dispatch to the appropriate main().
die 'svn-role mode is broken when there are >=2 entries in Approved; '.
    'see <http://mail-archives.apache.org/mod_mbox/subversion-dev/201404.mbox/%3C20140417111215.GB1802@tarsus.local2%3E> '.
    'and <http://mail-archives.apache.org/mod_mbox/subversion-dev/201404.mbox/%3C8738h36mwh.fsf@ntlworld.com%3E> '.
    'for details.'
    if $MAY_COMMIT;

given (basename($0)) {
  when (/^b$|backport/) {
    chdir dirname $0 or die "Can't chdir: $!" if /^b$/;
    &backport_main(@ARGV);
  }
  when (/^n$|nominate/) {
    chdir dirname $0 or die "Can't chdir: $!" if /^n$/;
    &nominate_main(@ARGV);
  }
  default {
    &backport_main(@ARGV);
  }
}
