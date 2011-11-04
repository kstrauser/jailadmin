# $Id: Jail.pm 138 2004-11-19 21:04:24Z kirk $

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

# Use Subversion tags to dynamically create the module version
$VERSION = '$Rev: 138 $';
$VERSION =~ s/\$Rev:\s*(.*)\s*\$/$1/;

require 'dumpvar.pl';
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
            'debug'                => 0,
            'default_fstab'        => '/etc/fstab',
            'default_shutdown'     => 'naive',
            'default_startcommand' => '/bin/sh /etc/rc',
            'default_usejtools'    => 0,
            'maxparallel'          => 1
           );
my %jaildata;

open INFILE, $conffile or die "Unable to read the configuration file: $!";

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

        # Handle group definitions
        if ($key =~ /^group_/)
        {
            $conf{$key} = [canonicalizeList(split /\s*,\s*/, $value)];
        }
        else
        {
            $conf{$key} = $value;
        }
        next;
    }

    # Unset global config options
    if ($inline =~ /^!\s*(.*)$/ and not $sub)
    {
        delete $conf{$1};
        next;
    }

    # Start a new server
    unless ($sub)
    {
        $server = $inline;
        foreach my $key (keys %conf)
        {
            if ($key =~ /^default_(.*)$/)
            {
                $jaildata{$server}{$1} = $conf{$key};
            }
        }
        $jaildata{$server}{'dir'} = "$conf{'jaildir'}/$server";

        next;
    }

    # Unset server-specific options
    if ($inline =~ /^\!\s*(.*)$/)
    {
        delete $jaildata{$server}{$1};
        next;
    }

    # Set server-specific options
    my ($key, $value) = (split /\s*:\s*/, $inline)[0, 1];

    # Pre-process select key types
    if ($key eq 'dir')
    {
        $value = "$conf{'jaildir'}/$jaildata{$server}{'dir'}" unless $value =~ /^\//;
    }

    # Make the assignment
    $jaildata{$server}{$key} = $value;
}

# Defined the "all" group if it is not already set.
if (not defined $conf{'group_all'})
{
    $conf{'group_all'} = [ canonicalizeList('ALL') ];
}

# Finally, sanity-check the configuration.
my $procismounted;
foreach my $server (keys %jaildata)
{
    if ($jaildata{$server}{'shutdown'} eq 'emulated' and not
        $jaildata{$server}{'usejtools'})
    {
        die "In server $server, you must set usejtools in order to use the emulated shutdown method, stopped";
    }
    if (not $jaildata{$server}{'usejtools'})
    {
        unless (defined $procismounted)
        {
            open INPIPE, "mount -t procfs |";
            $procismounted = grep / \/proc/, <INPIPE>;
        }
        unless ($procismounted)
        {
            die "In server $server, you must set usejtools unless /proc is mounted, stopped";
        }
    }
}

# Display the configuration hashes
if ($conf{'debug'} > 2)
{
    print "System options:\n";
    main::dumpValue(\%conf);

    print "\nServer options:\n";
    main::dumpValue(\%jaildata);

    print "\n\n";
}

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

1;


############################################################
#### Subroutines                                        ####
############################################################

# Apply a set of rules to a jail's devfs
sub applyDevfsRuleset
{
    my $server = shift;
    my $ruleset = shift;

    my $devdir = "$jaildata{$server}{'dir'}/dev";

    my $shellscript = <<__EOSS__;
#!/bin/sh

. /etc/defaults/rc.conf
. /etc/rc.subr

devfs_init_rulesets
devfs_set_ruleset $ruleset $devdir
devfs -m $devdir rule applyset
__EOSS__

    open OUTPIPE, "| /bin/sh";
    print OUTPIPE $shellscript;
    close OUTPIPE;
}

sub canonicalizeList
{
    my $count = 0;
    my %servers;

    while (defined ($server = shift @_))
    {
        # A list of all servers
        if ($server eq 'ALL')
        {
            foreach my $key (keys %jaildata)
            {
                $servers{$key} = $count++;
            }
        }

        # Remove a specific server
        elsif ($server =~ /^!\s*(.*)$/)
        {
            delete $servers{$1};
        }

        # Add a single server
        elsif (defined ($jaildata{$server}))
        {
            $servers{$server} = $count++;
        }

        # Add a group of servers
        elsif (defined ($conf{"group_$server"}))
        {
            foreach my $key (@{$conf{"group_$server"}})
            {
                $servers{$key} = $count++;
            }
        }

        else
        {
            debug('No server or group named $server exists.');
        }
    }

    return (sort { $servers{$a} <=> $servers{$b} } keys %servers);
}

sub debug
{
    my $message = shift;
    my $level = shift || 1;
    print STDERR ">>> $message\n" if $conf{'debug'} >= $level;
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

sub getJid
{
    my $server = shift;

    die "You must set 'usejtools' to use getJid(), stopped"
        if not $jaildata{$server}{'usejtools'};

    open INPIPE, "jls |" or die "Unable to open a pipe from 'jls': $!";

    # Toss the first line
    $_ = <INPIPE>;

    my $jid;
    while (defined ($_ = <INPIPE>))
    {
        chomp;
        s/^\s*(.*?)\s*$/$1/;
        my @fields = split /\s+/, $_;
        if ($fields[1] eq $jaildata{$server}{'ip'})
        {
            $jid = $fields[0];
            last;
        }
    }
    close INPIPE;

    return $jid || 0;
}

sub getProcInfo
{
    my $server = shift;
    my %proclist = getProcList($server);

    if ($jaildata{$server}{'usejtools'})
    {
        # Note that getProcList() already does all of the work if
        # usejtools is set, since it's extremely cheap to parse the
        # additional fields of the "ps" output when building the
        # process list.
        return %proclist;
    }

    my @psdata;
    foreach my $pid (keys %proclist)
    {
        open INPIPE, "ps wup $pid |" or die "Couldn't open the ps pipe: $!";
        $_ = <INPIPE>;
        push @psdata, <INPIPE>;
        close INPIPE;
    }
    return psToHash(@psdata);
}

# Get a list of all PIDs currently running in a particular jail
sub getProcList
{
    my $server = shift;
    my $hostname = $jaildata{$server}{'hostname'};

    return () unless isRunning($server);

    if ($jaildata{$server}{'usejtools'})
    {
        my $pscmd = 'ps wxua';
        my @psout = jexecute($server, $pscmd);
        shift @psout;
        my %procs = psToHash(@psout);

        # Delete the entry for the highest-numbered command that looks
        # exactly like our ps command from above.  If we don't do
        # this, then ps itself appears in the list, which probably
        # isn't what the use wants.  Note that we can't be sure that
        # the found ps is really *our* ps, but it's pretty likely, and
        # probably not worth being pedantic.
        my $removepid;
        foreach my $pid (sort { $a <=> $b } keys %procs)
        {
            $removepid = $pid if $procs{$pid}{'user'} eq 'root' and $procs{$pid}{'command'} eq $pscmd;
        }
        delete $procs{$removepid} if defined $removepid;

        return %procs;
    }
    else
    {
        updateProcessList();
        return %{$processList{$hostname}};
    }
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

sub isRunning
{
    my $server = shift;

    my $hostname = $jaildata{$server}{'hostname'};

    if ($jaildata{$server}{'usejtools'})
    {
        return getJid($server) ? 1 : 0;
    }
    else
    {
        updateProcessList();
        return keys %{$processList{$hostname}} ? 1 : 0;
    }
}

sub jexecute
{
    my $server = shift;
    my $command = shift;

    die "You must set 'usejtools' to use jexecute(), stopped"
        if not $jaildata{$server}{'usejtools'};

    my $jid = getJid($server);
    return if not $jid;

    debug("Executing \"$command\"");

    open INPIPE, "jexec $jid $command |" or die "Unable to open a pipe from 'jexec': $!";
    my @retlist;
    while (defined ($_ = <INPIPE>))
    {
        chomp;
        push @retlist, $_;
    }
    close INPIPE;

    return @retlist;
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
        system "mount -F $jaildata{$server}{'fstab'} $jaildata{$server}{'dir'}/$fs";
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

    system "jail $jaildata{$server}{'dir'} $jaildata{$server}{'hostname'} $jaildata{$server}{'ip'} $jaildata{$server}{'startcommand'}";
}

sub psToHash
{
    my %rethash;
    foreach my $psline (@_)
    {
        chomp $psline;
        my @fields = split /\s+/, $psline, 11;
        my $pid = $fields[1];
        my %procinfo =
            (
            'user'    => $fields[0],
            'pid'     => $fields[1],
            'cpu'     => $fields[2],
            'mem'     => $fields[3],
            'vsz'     => $fields[4],
            'rss'     => $fields[5],
            'tt'      => $fields[6],
            'stat'    => $fields[7],
            'started' => $fields[8],
            'time'    => $fields[9],
            'command' => $fields[10]
            );
        $rethash{$pid} = \%procinfo;
    }
    return %rethash;
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

sub stop
{
    my $server = shift;
    my $state = shift;

    my $sleep = 0;
    my $nextstate;

    debug("--- Server: $server state $state");

    # Old-style shutdown ('naive'): All processes get the TERM
    # signal, then after a delay, all remaining processes get KILLed.
    # This is similar to the final stages of FreeBSD's own shutdown
    # process.  While it isn't the cleanest shutdown possible, it has
    # the advantage of working on every FreeBSD system, and there have
    # not been any reported problems with it.

    # New-style shutdown ('emulated'): This executes the jail's own
    # rc.shutdown script to stop processes by their preferred method.
    # Then, the process detailed above shuts down the remaining
    # processes.  It mimics the full FreeBSD shutdown very closely,
    # but depends on certain system executables that may not be
    # present on older systems.

    $state == 1 and do {
        if ($jaildata{$server}{'shutdown'} eq 'emulated')
        {
            debug('Executing /etc/rc.shutdown.');
            jexecute($server, 'sh /etc/rc.shutdown');
            debug('Done.  Sleeping at least 5 seconds.');
            $sleep = 5;
            $nextstate = 2;
        }
        else
        {
            $state = 2;
        }
    };

    # Send term signal
    $state == 2 and do {
        # TERM all of the processes
        debug('Sending signal TERM to all processes.  Sleeping at least 5 seconds.');
        Jail::signalProcs($server, 'TERM');
        $sleep = 5;
        $nextstate = $state + 1;
    };

    # Sleep 10 seconds for slow processes
    $state == 3 and do {
        if (Jail::isRunning($server))
        {
            debug('Some processes are still running.  Sleeping at least 10 seconds.');
            $sleep = 10;
            $nextstate = $state + 1;
        }
        else
        {
            debug('No processess left.');
            # Skip the next process check - we've already passed.
            $nextstate = $state + 2;
        }
    };

    # Send kill signal
    $state == 4 and do {
        if (Jail::isRunning($server))
        {
            debug('Sending remaining processes the KILL signal.  Sleeping at least 2 seconds.');
            Jail::signalProcs($server, 'KILL');
        }
        else
        {
            debug('No processess left.');
        }
        $sleep = 2;
        $nextstate = $state + 1;
    };

    # Unmount specified filesystems
    $state == 5 and do {
        debug('Unmounting filesystems.');
        Jail::umount($server);
        $nextstate = 0;
    };

    return ($nextstate, $sleep);
}

sub umount
{
    my $server = shift;

    my $mountlist = $jaildata{$server}{'mount'} or return;
    my @entry = split ',', $mountlist;

    foreach my $fs (reverse @entry)
    {
        $fs = $1 if $fs =~ /^(.*)\((\d+)\)$/;
        system "umount $jaildata{$server}{'dir'}/$fs";
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
        # print "PID: $pid\n" unless defined $cmdline;
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
