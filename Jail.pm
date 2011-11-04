# $Id: Jail.pm 66 2004-04-02 19:44:14Z kirk $

# This software was written by Kirk Strauser <kirk@strauser.com>, and may be
# freely distributed under the terms of the BSD License.
#
# Please submit any changes to this program back to the author so that they
# can be easily distributed to other others who might be interested.


############################################################
#### Package definition                                 ####
############################################################

package Jail;
require Exporter;

@ISA       = qw(Exporter);
@EXPORT    = qw();
@EXPORT_OK = qw();

# Use CVS tags to dynamically create the module version
$VERSION = '$Revision: 1.6 $';
$VERSION =~ s/\$Revision:\s*(.*)\s*\$/$1/;

use strict;
use Config;
use Getopt::Long;

############################################################
#### Configuration section                              ####
############################################################

my $conffile = '/usr/local/etc/jailadmin.conf';

Getopt::Long::Configure('pass_through');
Getopt::Long::GetOptions('conffile=s', \$conffile);

my %conf = (
	    'debug'       => 0,
	    'maxparallel' => 1
	   );
my %jaildata;

open INFILE, $conffile or die "Unable to read the configuration file: $!";

## Example of the trivially simple file format (I'm not a big fan of writing
## parsers):
##
## programopt1 = value1
## programopt2 = value2
##
## # Server configuration
## server1
##     opt1: val1
##     opt2: val2

my $server;
while (defined (my $inline = <INFILE>))
{
    chomp $inline;
    $inline =~ s/\#.*$//;             # Remove comments
    next unless $inline =~ /\S/;      # Skip blank lines
    my $sub = $inline =~ /^\s+/ || 0; # Is this line a subordinate setting?

    $inline =~ s/^\s*(.*)\s*$/$1/;

    # Set global config options
    if ($inline =~ /=/)
    {
	my ($key, $value) = (split /\s*=\s*/, $inline)[0, 1];
	$conf{$key} = $value;
	next;
    }

    # Set server-specific options
    unless ($sub)
    {
	$server = $inline;
    }
    else
    {
	my ($key, $value) = (split /\s*:\s*/, $inline)[0, 1];
	$jaildata{$server}{$key} = $value;
    }
}

# Validate and re-format the group_ definitions.
foreach my $group (keys %conf)
{
    next unless $group =~ /^group_/;
    my @worklist;

    # Remove non-existent entries and duplicates, and re-format the
    # comma-separated list as an array.
    foreach my $server (split /\s*,\s*/, $conf{$group})
    {
	if (not defined $jaildata{$server})
	{
	    debug('No server named $server exists.');
	    next;
	}
	push @worklist, $server;
    }

    $conf{$group} = [ removeDupes(@worklist) ];
}

# Defined the "all" group if it's not already set.
if (not defined $conf{'group_all'})
{
    $conf{'group_all'} = [ sort keys %jaildata ];
}

# Apply default configuration options to each server configuration
# that doesn't define them.
foreach my $key (keys %conf)
{
    # Examine each setting that begins with "default_".
    next unless $key =~ /^default_(.*)$/;
    my $optname = $1;
    foreach $server (keys %jaildata)
    {
	$jaildata{$server}{$optname} = $conf{$key}
	    unless defined $jaildata{$server}{$optname};
    }
}

## Test the configuration parser
# foreach my $server (keys %jaildata)
# {
#     print "$server\n";
#     foreach my $key (keys %{$jaildata{$server}})
#     {
# 	print "  $key => $jaildata{$server}{$key}\n";
#     }
# }

# From the 'perlipc' Perldoc page:
my %signo;
my $i = 0;
defined $Config{sig_name} || die "No sigs?";
foreach my $name (split(' ', $Config{sig_name})) {
    $signo{$name} = $i;
    $i++;
}

my %processList;
my %uidcache;

updateProcessList();

1;


############################################################
#### Subroutines                                        ####
############################################################

# Apply a set of rules to a jail's devfs
sub applyDevfsRuleset
{
    my $server = shift;
    my $ruleset = shift;

    my $devdir = "$conf{'jaildir'}/$server/dev";

    my $shellscript = <<__EOSS__;
#!/bin/sh

. /etc/defaults/rc.conf
. /etc/rc.subr

ruleset=devfsrules_jail
devdir=/var/jail/virtual1/dev

devfs_init_rulesets
devfs_set_ruleset $ruleset $devdir
devfs -m $devdir rule applyset
__EOSS__

    open OUTPIPE, "| /bin/sh";
    print OUTPIPE $shellscript;
    close OUTPIPE;
}

sub debug
{
    my $message = shift;
    print STDERR ">>> $message\n" if $conf{'debug'};
}

# Get the names of all defined jails
sub getJailList
{
    return sort (keys %jaildata);
}

sub getJailInfo
{
    my $server = shift;
    return \%{$jaildata{$server}};
}

sub getMatchingJailNames
{
    my @retlist;
    my @serverlist;
    while (defined ($server = shift @_))
    {
	if (defined ($jaildata{$server}))
	{
	    push @serverlist, $server;
	    next;
	}
	if (defined ($conf{"group_$server"}))
	{
	    push @serverlist, @{$conf{"group_$server"}};
	    next;
	}
	debug('No server or group named $server exists.');
    }

    return removeDupes(@serverlist);
}

# Get a list of all PIDs currently running in a particular jail
sub getProcList
{
    my $server = shift;
    my $hostname = $jaildata{$server}{'hostname'};
    return jailHasProcesses($server) ? %{$processList{$hostname}} : ();
}

# Caching version of getpwuid.  The syscall may be expensive, and it may
# otherwise potentially be called thousands of times with the same arguments.
sub getpwuidcache
{
    my $uid = shift;
    unless (defined ($uidcache{$uid}))
    {
	$uidcache{$uid} = getpwuid $uid;
    }
    return $uidcache{$uid};
}

sub jailHasProcesses
{
    my $server = shift;
    my $hostname = $jaildata{$server}{'hostname'};
    return keys %{$processList{$hostname}} ? 1 : 0;
}

sub maxparallel
{
    return $conf{'maxparallel'};
}

sub mount
{
    my $server = shift;

    my $mountlist = $jaildata{$server}{'mount'} or return;
    my @entry = split ',', $mountlist;

    foreach my $fs (@entry)
    {
	my $sleep = 0;
	if ($fs =~ /^(.*)\((\d+)\)$/)
	{
	    $fs = $1;
	    $sleep = $2;
	}
	system "mount $conf{'jaildir'}/$server/$fs";
	sleep $sleep if $sleep;
    }

    if (defined $jaildata{$server}{'devfsruleset'})
    {
	applyDevfsRuleset($server, $jaildata{$server}{'devfsruleset'});
    }
}

sub signalProcs
{
    my $server = shift;
    my $signal = shift;

    my %temp = getProcList($server);
    my @pids = keys %temp;
    kill $signo{$signal}, @pids;
}

sub launch
{
    my $server = shift;

    system "jail $conf{'jaildir'}/$server $jaildata{$server}{'hostname'} $jaildata{$server}{'ip'} /bin/sh /etc/rc";
}

sub removeDupes
{
    my @retlist;
    foreach my $entry (@_)
    {
	push @retlist, $entry if not grep /^$entry$/, @retlist;
    }
    return @retlist;
}

sub umount
{
    my $server = shift;

    my $mountlist = $jaildata{$server}{'mount'} or return;
    my @entry = split ',', $mountlist;

    foreach my $fs (reverse @entry)
    {
	$fs = $1 if $fs =~ /^(.*)\((\d+)\)$/;
	system "umount $conf{'jaildir'}/$server/$fs";
    }
}

sub updateProcessList
{
    %processList = ();

    opendir INDIR, '/proc' or die "Unable to read the /proc filesystem: $!";
    foreach my $pid (readdir INDIR)
    {
	next if $pid =~ /^\.\.?$/ or $pid eq 'CURPROC';

	unless (open INPROC, "/proc/$pid/status")
	{
	    print STDERR "Unable to read /proc/$pid: $!";
	    next;
	}
	my $status = <INPROC>;
	close INPROC;

	my ($procname,
	    $uid,
	    $gids,
	    $hostname) = (split /\s+/, $status)[0, 11, 13, 14];

	# Get the process' command line
	unless (open INPROC, "/proc/$pid/cmdline")
	{
	    print STDERR "Unable to read /proc/$pid/cmdline: $!";
	    next;
	}
	my $cmdline = <INPROC> || '';
	close INPROC;

	# Clean up the results a little
	print "PID: $pid\n" unless defined $cmdline;
	$cmdline =~ s/\000/ /g;
	$cmdline =~ s/\s*$//;

	my @uidinfo = getpwuidcache($uid);

	my %procinfo = 
	    (
	     'hostname' => $hostname,
	     'uid'      => $uid,
	     'user'     => $uidinfo[0],
	     'procname' => $procname,
	     'cmdline'  => $cmdline
	    );

	$processList{$hostname}{$pid} = \%procinfo;
    }
    closedir INDIR;
}
