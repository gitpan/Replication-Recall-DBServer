# -*-cperl -*-
#
# Replication::Recall::DBServer - Database replication server.
# Copyright (c) 2000 Ashish Gulhati <hash@netropolis.org>
#
# All rights reserved. This code is free software; you can
# redistribute it and/or modify it under the same terms as Perl
# itself.
#
# $Id: DBServer.pm,v 1.14 2001/05/27 11:07:17 cvs Exp $

package Replication::Recall::DBServer;

BEGIN {
}

use DBI;
use Carp;
use strict;
use File::Rsync;
use Time::HiRes qw ( sleep );
use Data::Dumper qw ( Dumper );
use Replication::Recall::Client;
use Replication::Recall::Server;
use vars qw( $VERSION $AUTOLOAD );
use POSIX qw( :sys_wait_h :signal_h :errno_h );

( $VERSION ) = '$Revision: 1.14 $' =~ /\s+([\d\.]+)/;
my $recovering = {};

sub reaper { 
  my $pid = waitpid(-1, WNOHANG); 
  if (WIFEXITED($?)) {
    $recovering->{$pid}->{Rsync} = 0;
    delete $recovering->{$pid};
  }
  $SIG{CHLD} = \&reaper;
}

$SIG{CHLD} = \&reaper;

sub new { 
  my $class = shift; my %opts = @_;
  my $self = { 
	      ID          => @{$opts{Replicas}}[0],
	      DSN         => $opts{DSN},
	      Replicas    => $opts{Replicas},
	      Debug       => $opts{Debug},
	      SyncPath    => $opts{SyncPath},
	      SyncCmd     => $opts{SyncCmd},
	      StopServer  => $opts{StopServer},
	      StartServer => $opts{StartServer},
	      String      => Replication::Recall::Client::new_String(),
	      Exception   => Replication::Recall::Client::new_RecallException(),
	      Counter     => 0,
	      Rsync       => 0,
	      Syncing     => 0,
	      Writelocked => 0,
	      Donesync    => 0,
	      Finalsync   => 0,
	      Firstsync   => 0,
	      Syncwait    => 0,
	      SyncCtr     => 0,
	      SyncData    => {},
	     };
  bless $self, $class;
  $self->debug("init $self->{ID}\n"); 
  return $self;
}

sub debug {
  my $self = shift;
  print @_ if $self->{Debug};
}

sub run {
  my $self = shift;
  my $opts = Replication::Recall::Server::new_EchoOptions();
  my $echo = Replication::Recall::Server::new_Echo();
  my $names = join(',', @{$self->{Replicas}});
  Replication::Recall::Server::Logger_disable_debug_messages 
    (Replication::Recall::Server::Logger_instance()) unless ($self->{Debug});
  Replication::Recall::Server::Echo_start
    ($echo, $names, $opts, $self) and die "Couldn't start server.\n";
  Replication::Recall::Server::Echo_loop($echo);
}

sub read {
  my $self = shift;
  $self->debug("Reading @_\n");
  $self->syncing(0), $self->donesync(1) if $_[0] eq 'DoneSync';
  $self->syncing(1), return 'SyncLocked' if $_[0] eq 'FinalSync' and !$self->writelocked();
  $self->writelocked(1), return 'Locked' if $_[0] eq 'LockWrite' and !$self->syncing();
}

sub write {
  my $self = shift;
  $self->debug("Writing @_\n");
  my $VAR1; eval($_[0]); my %args = %$VAR1; my %ret;
  local $SIG{__WARN__} = sub { ($ret{Warn} = $_[0]) =~ s/ at \S+ line \d+\.?\s*\n$// };
  local $SIG{__DIE__} = sub { ($ret{Die} = $_[0]) =~ s/ at \S+ line \d+\.?\s*\n$// };
  if ($args{Meta} eq 'Top' and $args{Method} eq 'driver') {
    my $d = shift @{$args{Args}};
    return undef unless $self->{DSN} =~ /DBI:([^:]+):/; my $realdbd = $1;
    $self->{Handles}->{++$self->{Counter}}->{Handle} = 
      eval { DBI->install_driver($realdbd, @{$args{Args}}) };
    $self->{Handles}->{$self->{Counter}}->{Command} = $_[0];
    $ret{Eval} = $@ if $@; delete $self->{Handles}->{$self->{Counter}} 
      unless $self->{Handles}->{$self->{Counter}}->{Handle};
    $ret{Error} = $DBI::errstr; $ret{Err} = $DBI::err; $ret{State} = $DBI::state;
    $ret{Return} = [ $self->{Handles}->{$self->{Counter}}?$self->{Counter}:undef ];
  }
  elsif (($args{Meta} eq 'AutoDR' and $args{Method} eq 'connect') 
	 or ($args{Meta} eq 'AutoDB' and $args{Method} eq 'prepare')) {
    return undef unless my $handle = $self->{Handles}->{$args{Handle}}; 
    my $method = $args{Method};
    unshift (@{$args{Args}}, $self->{DSN}) if $method eq 'connect';
    $self->{Handles}->{++$self->{Counter}}{Handle} = 
      eval { $$handle{Handle}->$method(@{$args{Args}}) };
    delete $self->{Handles}->{$self->{Counter}} 
      unless $self->{Handles}->{$self->{Counter}}->{Handle}; 
    $self->{Handles}->{$self->{Counter}}->{Command} = $_[0]; $ret{Eval} = $@ if $@;
    $ret{Error} = $$handle{Handle}->errstr(); $ret{Err} = $$handle{Handle}->err(); 
    $ret{State} = $$handle{Handle}->state(); 
    $ret{Return} = [ $self->{Handles}->{$self->{Counter}}?$self->{Counter}:undef ];
  }
  elsif ($args{Meta} =~ /^Auto/) {
    return undef unless my $handle = $self->{Handles}->{$args{Handle}}; 
    my $method = $args{Method};
    my @eval = eval { $$handle{Handle}->$method(@{$args{Args}}) };
    delete $ret{Die}, @eval = eval { $$handle{Handle}->func(@{$args{Args}}, $method) }
      if $ret{Die} =~ /Can\'t locate object method/;
    $ret{Return} = [ @eval ]; $ret{Eval} = $@ if $@;
    if ($args{Method} eq 'DESTROY') {
      $self->debug("Foo! $args{Handle}\n");
      delete $self->{Handles}->{$args{Handle}};
    }
    else {
      $ret{Error} = $$handle{Handle}->errstr(); $ret{Err} = $$handle{Handle}->err(); 
      $ret{State} = $$handle{Handle}->state(); 
    }
  }
  $self->writelocked(0);
  my $ret = defined &Data::Dumper::Dumpxs?Data::Dumper::DumperX(\%ret):Dumper(\%ret);
}

sub start_recovery() { 
  my $self = shift;
  $self->debug("start_recovery $self->{ID}\n");
  $self->firstsync(1);
  return 0;
}

sub recover_some() {
  my $self = shift;
  $self->debug("recover_some $self->{ID}\n");
  my $VAR1 = undef; eval $_[0]; my %ret = %$VAR1; 
  unless ($self->{Rsync}) {
    if ($self->firstsync() or $self->finalsync()) {
      if (my $pid = fork()) {
	$recovering->{$pid} = $self;
	my $final = $self->finalsync()?'Final ':'';
	$self->debug($final."rsync $ret{Replica} -> $self->{ID}\n");
	$self->syncwait(1), $self->firstsync(0) if $self->firstsync();
	$self->finalsync(0) if $self->finalsync(); $self->{Rsync} = 1; 
      }
      else {
	(my $src = $ret{Replica}) =~ s/:.*/:$ret{SyncPath}/;
	if ($ret{SyncCmd} && $ret{SyncPath} && $self->{SyncPath}) {
	  my $rsync = File::Rsync->new
	    ( { archive => 1, compress => 1, rsh => $self->{SyncCmd} } );
	  $rsync->exec( { src => $src, dest => $self->{SyncPath} } ) 
	    or $rsync->realstatus == -1 or warn "rsync failed\n";
	}
	if ($self->finalsync()) {
	  $self->debug("Database recovery complete. Restarting server\n");
	  if ($self->{StopServer} and $self->{StartServer}) {
	    &{$self->{StopServer}}; 
	    &{$self->{StartServer}}
	  }
	  $self->debug("Server restarted. Recovering open handles\n");
	  foreach (sort {$a <=> $b} keys %{$ret{Handles}}) {
	    $self->{Counter} = $_-1;
	    my $VAR1 = $self->write ($ret{Handles}->{$_}->{Command});
	    $self->debug ($VAR1);
	  }
	}
	exit();
      }
    }
    else {
      my $message = $self->syncwait()?'FinalSync':'DoneSync'; 
      my $clerk = Replication::Recall::Client::new_Clerk($ret{Replica});
      Replication::Recall::Client::Clerk_read
	($clerk, $message, $self->{String}, $self->{Exception});
      my $x = Replication::Recall::Client::String_c_str($self->{String});
      $self->finalsync(1), $self->syncwait(0) if $x eq 'SyncLocked';
    }
  }
  return 0;
}

sub end_recovery() {
  my $self = shift;
  $self->firstsync(0); $self->finalsync(0); $self->{Rsync} = 0;
  $self->debug("end_recovery $self->{ID}\n");
  return 0;
}

sub start_catchup() { 
  my $self = shift;
  $self->debug("start_catchup $self->{ID}\n"); my $result = $self->{SyncCtr}++; 
  my %ret = ( Replica  => $self->{ID}, Handles => $self->{Handles},
	      SyncPath => $self->{SyncPath}, SyncCmd  => $self->{SyncCmd},  );
  $self->{SyncData}->{$result} = 
    defined &Data::Dumper::Dumpxs?Data::Dumper::DumperX(\%ret):Dumper(\%ret);
  return $result;
}

sub catchup_next() { 
  my $self = shift; my $index = $_[0];
  $self->debug("catchup_next $index $self->{ID}\n"); 
  $self->donesync(0), return '' if $self->donesync();
  sleep 0.5; return $self->{SyncData}->{$index};
}

sub end_catchup($) {
  my $self = shift; my $index = $_[0];
  $self->debug("end_catchup $self->{ID}\n"); 
  delete $self->{SyncData}->{$index};
  return 0;
}

sub load_epochs() {
  my $self = shift;
  $self->debug("load epochs $self->{ID}\n");
  return 0;
}

sub save_epochs() {
  my $self = shift; my ($data, $service, $prospective, $big) = @_;
  $self->debug("save epochs $self->{ID} $data $service $prospective $big\n");
  return 0;
}

sub destroy() { 
  my $self = shift;
  $self->debug("destroy $self->{ID}\n"); 
}

sub AUTOLOAD {
  my ($self, $val) = @_; (my $auto = $AUTOLOAD) =~ s/.*:://;
  if ($auto =~ /^(syncing|donesync|(final|first)sync|
                  syncwait|writelocked)$/x) {
    $self->debug("$auto $self->{ID}\n");
    $self->{"\u\L$auto"} = $val if (defined $val);
    return $self->{"\u$auto"};
  }
  else {
    croak "Could not AUTOLOAD method $auto.";
  }
}

END {
}

"True Value";
__END__

=head1 NAME 

Replication::Recall::DBServer - Database replication server.

=head1 VERSION

 $Revision: 1.14 $
 $Date: 2001/05/27 11:07:17 $

=head1 SYNOPSIS

  use Replication::Recall::DBServer;

  my $port = 8500;

  my $server = new Replication::Recall::DBServer
    ( Replicas    => ["192.168.1.1:$port",
		      "192.168.1.2:$port",
                      "192.168.1.3:$port"],

      DSN         => 'DBI:mysql:database=replica1;host=localhost;port=',

      StopServer  => sub { system ('mysqladmin','shutdown') },

      StartServer => sub { system ('start-stop-daemon', 
	                           '--start', '-b', '-x', 
                                   '/usr/bin/safe_mysqld') },

      SyncPath    => '/var/lib/mysql/replica1/',
      SyncCmd     => 'ssh -l mysql',
      Debug       => 1
    );

  unless (fork) { $server->run() }
  wait();

=head1 DESCRIPTION

This module interfaces to Recall, a data replication library written
by Eric Newton, to enable the setup of replicated database servers.

Recall is based on a data replication algorithm developed at DEC's SRC
for the Echo filesystem. It implements a fast protocol with low
network overhead and guranteed fault tolerance as long as n of 2n-1
replica nodes are up.

The Replication::Recall::DBServer module provides the functionality
needed to set up replication servers to be accessed through the
DBD::Recall module.

You'll probably need root access, or at least access to restart your
database server, to make this work properly. You probably don't want
to use the same database server to host databases other than the
replicated one because Replication::Recall::DBServer will stop and
restart the server during replica recovery.

Further - if you want to use Replication::Recall::DBServer with
PostgreSQL, you'll definitely have to dedicate an entire PostgreSQL
"database system" to the replicated database. This is necessary
because PostgreSQL maintains unique object identifiers across an
entire database system, which can't be kept consistent across replicas
otherwise.

It's a good idea to never access or update replicas without going
through the replication system, or you may end up with lost or
inconsistent data, unless you really know what you're doing.

I've only tried Replication::Recall::DBServer with MySQL so far on
Debian GNU/Linux. If you get it to work with another database engine
or on another operating system, please email me about your experiences
so I can include information about your platform in future releases.

=head1 CONSTRUCTOR

=over 2

=item B<new ()>

Creates a new replication server object. Takes a hash argument list
with the following keys:

=item B<Replicas> 

A reference to an array of all the replica servers in this replica
set, in hostname:port format.

=item B<DSN>

The DBI format DSN (Data Source Name) for the actual underlying
database to be used by this replica. This is what you'd pass to DBI's
B<connect()> method if you were using a plain old DBD driver to access
this replica of the database.

=item B<StopServer>

A code reference to a routine that will stop the database server
during the final stage of bringing this replica up to date with the
others in the set.

=item B<StartServer>

A code reference to a routine that will start the database server
after the final stage of bringing this replica up to date with the
others in the set. It's probably wise to arrange for this code to
completely dissociate the new database server processes from your
script's program group, so that they don't die if the perl process
does.

=item B<SyncPath>

The path to the directory that should be rsynced during replica
recovery. This filesystem-based method of syncing replicas is a hack,
admittedly, but it's the most generally applicable method I could
think of. It might not work with database systems that don't keep all
their database information in one neat directory tree. If you come up
against a limitation of this sync method, I'd like to hear about it.

=item B<SyncCmd>

The command to use to establish a connection to the master replica
while rsyncing. This must establish an 8-bit clean link suitable for
rsync to work across, and should be totally non-interactive, so you
need to set up your ssh keys or (if you don't give a damn about
security) .rhosts access accordingly.

=item B<Debug>

Set true to see a whole bunch of debugging information.

=back

=head1 METHODS

=over 2

=item B<run()>

Run the server. Doesn't return if all goes well.

=back

=head1 AUTHOR

Replication::Recall::DBServer is Copyright (c) 2000-2001 Ashish
Gulhati <hash@netropolis.org>.  All Rights Reserved.

=head1 ACKNOWLEDGEMENTS

Thanks to Barkha for inspiration, laughs and all 'round good times;
and to Eric Newton, Gurusamy Sarathy, Larry Wall, Richard Stallman and
Linus Torvalds for all the great software.

=head1 LICENSE

This code is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 DISCLAIMER

This is free software. If it breaks, you own both parts.

=cut

'True Value';
