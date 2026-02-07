#!/usr/bin/env perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use IPC::Open3;
use IO::Handle;
use IO::Select;
use Symbol qw(gensym);

my $root = abs_path(dirname(__FILE__) . "/..");
my $mruby = $ENV{RMAKE_MRUBY} || "$root/mruby/bin/mruby";
my $rmake = "$root/tools/rmake";
my $self = $0;

STDOUT->autoflush(1);
STDERR->autoflush(1);

if (@ARGV == 1 && ($ARGV[0] eq '-v' || $ARGV[0] eq '--version')) {
  print "GNU Make 4.4.1\n";
  exit 0;
}

my @out = @ARGV;

$ENV{MAKE} = $self;
$ENV{RMAKE_JOBS} = '1' if !defined($ENV{RMAKE_JOBS}) || $ENV{RMAKE_JOBS} eq '';
$ENV{TMPDIR} = '/tmp';

my $err = gensym;
my $stdin_data = '';
if (!-t STDIN) {
  local $/ = undef;
  my $d = <STDIN>;
  $stdin_data = defined($d) ? $d : '';
}

my $pid = open3(my $stdin, my $stdout, $err, $mruby, $rmake, @out);
if (length($stdin_data) > 0) {
  print {$stdin} $stdin_data;
}
close($stdin);

my $all = '';
my @events = ();
my %pending = (
  out => '',
  err => '',
);

sub emit_line {
  my ($stream, $line, $rmake_path, $all_ref, $events_ref) = @_;
  return if $line eq "trace (most recent call last):\n";
  return if $line eq "trace (most recent call last):";
  return if $line =~ /^\Q$rmake_path\E:\d+: rmake failed with status \d+ \(RuntimeError\)\n?$/;
  $$all_ref .= $line;
  push @$events_ref, [($stream eq 'out' ? 1 : 0), $line];
}

my $sel = IO::Select->new();
$sel->add($stdout);
$sel->add($err);
while ($sel->count > 0) {
  for my $fh ($sel->can_read()) {
    my $buf = '';
    my $n = sysread($fh, $buf, 4096);
    if (!defined($n) || $n <= 0) {
      $sel->remove($fh);
      close($fh);
      next;
    }
    my $stream = ($fh == $stdout) ? 'out' : 'err';
    $pending{$stream} .= $buf;
    while ($pending{$stream} =~ s/\A(.*?\n)//s) {
      my $line = $1;
      emit_line($stream, $line, $rmake, \$all, \@events);
    }
  }
}
waitpid($pid, 0);
my $code = ($? >> 8);

for my $stream (qw(out err)) {
  if (length($pending{$stream}) > 0) {
    emit_line($stream, $pending{$stream}, $rmake, \$all, \@events);
    $pending{$stream} = '';
  }
}

for my $ev (@events) {
  if ($ev->[0]) {
    print STDOUT $ev->[1];
  } else {
    print STDERR $ev->[1];
  }
}
STDOUT->flush();

if ($code == 1 && ($all =~ /\*\*\*/ || $all =~ /requires an argument/)) {
  exit 2;
}
exit $code;
