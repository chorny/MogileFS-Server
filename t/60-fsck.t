# -*-perl-*-
# some of the comments match the comments in MogileFS/Worker/Fsck.pm
# _exactly_ for reference purposes
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Time::HiRes qw(sleep);
use MogileFS::Server;
use MogileFS::Test;
use HTTP::Request;
find_mogclient_or_skip();
use MogileFS::Admin;

my $sto = eval { temp_store(); };
if (!$sto) {
    plan skip_all => "Can't create temporary test database: $@";
    exit 0;
}

use File::Temp;
my %mogroot;
$mogroot{1} = File::Temp::tempdir( CLEANUP => 1 );
$mogroot{2} = File::Temp::tempdir( CLEANUP => 1 );
my $dev2host = { 1 => 1, 2 => 2, };
foreach (sort { $a <=> $b } keys %$dev2host) {
    my $root = $mogroot{$dev2host->{$_}};
    mkdir("$root/dev$_") or die "Failed to create dev$_ dir: $!";
}

my $ms1 = create_mogstored("127.0.1.1", $mogroot{1});
ok($ms1, "got mogstored1");
my $ms2 = create_mogstored("127.0.1.2", $mogroot{2});
ok($ms1, "got mogstored2");

while (! -e "$mogroot{1}/dev1/usage" &&
       ! -e "$mogroot{2}/dev2/usage") {
    print "Waiting on usage...\n";
    sleep(.25);
}

my $tmptrack = create_temp_tracker($sto);
ok($tmptrack);

my $admin = IO::Socket::INET->new(PeerAddr => '127.0.0.1:7001');
$admin or die "failed to create admin socket: $!";
my $moga = MogileFS::Admin->new(hosts => [ "127.0.0.1:7001" ]);
my $mogc = MogileFS::Client->new(
                                 domain => "testdom",
                                 hosts  => [ "127.0.0.1:7001" ],
                                 );
my $be = $mogc->{backend}; # gross, reaching inside of MogileFS::Client

# test some basic commands to backend
ok($tmptrack->mogadm("domain", "add", "testdom"), "created test domain");
ok($tmptrack->mogadm("class", "add", "testdom", "2copies", "--mindevcount=2"), "created 2copies class in testdom");
ok($tmptrack->mogadm("class", "add", "testdom", "1copy", "--mindevcount=1"), "created 1copy class in testdom");

ok($tmptrack->mogadm("host", "add", "hostA", "--ip=127.0.1.1", "--status=alive"), "created hostA");
ok($tmptrack->mogadm("host", "add", "hostB", "--ip=127.0.1.2", "--status=alive"), "created hostB");

ok($tmptrack->mogadm("device", "add", "hostA", 1), "created dev1 on hostA");
ok($tmptrack->mogadm("device", "add", "hostB", 2), "created dev2 on hostB");

sub wait_for_monitor {
    my $be = shift;
    my $was = $be->{timeout};  # can't use local on phash :(
    $be->{timeout} = 10;
    ok($be->do_request("clear_cache", {}), "waited for monitor")
        or die "Failed to wait for monitor";
    ok($be->do_request("clear_cache", {}), "waited for monitor")
        or die "Failed to wait for monitor";
    $be->{timeout} = $was;
}

sub wait_for_empty_queue {
    my ($table, $dbh) = @_;
    my $limit = 600;
    my $delay = 0.1;
    my $i = $limit;
    my $count;
    while ($i > 0) {
        $count = $dbh->selectrow_array("SELECT COUNT(*) from $table");
        return if ($count == 0);
        sleep $delay;
    }
    my $time = $delay * $limit;
    die "$table is not empty after ${time}s!";
}

sub full_fsck {
    my ($tmptrack, $dbh) = @_;

    # this should help prevent race conditions:
    wait_for_empty_queue("file_to_queue", $dbh);

    ok($tmptrack->mogadm("fsck", "stop"), "stop fsck");
    ok($tmptrack->mogadm("fsck", "clearlog"), "clear fsck log");
    ok($tmptrack->mogadm("fsck", "reset"), "reset fsck");
    ok($tmptrack->mogadm("fsck", "start"), "started fsck");
}

wait_for_monitor($be);

my ($req, $rv, %opts, @paths, @fsck_log, $info);
my $ua = LWP::UserAgent->new;
my $key = "testkey";
my $dbh = $sto->dbh;

use Data::Dumper;

# upload a file and wait for replica to appear
{
    my $fh = $mogc->new_file($key, "1copy");
    print $fh "hello\n";
    ok(close($fh), "closed file");
}

# first obvious fucked-up case:  no devids even presumed to exist.
{
    $info = $mogc->file_info($key);
    is($info->{devcount}, 1, "ensure devcount is correct at start");

    # ensure repl queue is empty before destroying file_on
    wait_for_empty_queue("file_to_replicate", $dbh);

    is($dbh->do("DELETE FROM file_on"), 1, "delete $key from file_on table");
    full_fsck($tmptrack, $dbh);
    do {
        @fsck_log = $sto->fsck_log_rows;
    } while (scalar(@fsck_log) < 3 && sleep(0.1));

    wait_for_empty_queue("file_to_queue", $dbh);
    @fsck_log = $sto->fsck_log_rows;

    my $nopa = $fsck_log[0];
    is($nopa->{evcode}, "NOPA", "evcode for no paths logged");

    # entering "desperate" mode
    my $srch = $fsck_log[1];
    is($srch->{evcode}, "SRCH", "evcode for start search logged");

    # wow, we actually found it!
    my $fond = $fsck_log[2];
    is($fond->{evcode}, "FOND", "evcode for start search logged");

    $info = $mogc->file_info($key);
    is($info->{devcount}, 1, "ensure devcount is correct at fsck end");
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 1, "get_paths returns correctly at fsck end");
}

# update class to require 2copies and have fsck fix it
{
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 1, "only one path exists before fsck");

    # _NOT_ using "updateclass" command since that enqueues for replication
    my $fid = MogileFS::FID->new($info->{fid});
    my $classid_2copies = $dbh->selectrow_array("SELECT classid FROM class WHERE dmid = ? AND classname = ?", undef, $fid->dmid, "2copies");
    is($fid->update_class(classid => $classid_2copies), 1, "classid updated");

    full_fsck($tmptrack, $dbh);

    do {
        @paths = $mogc->get_paths($key);
    } while (scalar(@paths) == 1 and sleep(0.1));
    is(scalar(@paths), 2, "replicated from fsck");

    $info = $mogc->file_info($key);
    is($info->{devcount}, 2, "ensure devcount is updated by replicate");

    do {
        @fsck_log = $sto->fsck_log_rows;
    } while (scalar(@fsck_log) == 0 and sleep(10));

    my $povi = $fsck_log[0];
    is($povi->{evcode}, "POVI", "policy violation logged by fsck");

    my $repl = $fsck_log[1];
    is($repl->{evcode}, "REPL", "replication request logged by fsck");
}

# wrong devcount in file column, but otherwise everything is OK
{
    foreach my $wrong_devcount (13, 0, 1) {
        is($dbh->do("UPDATE file SET devcount = ? WHERE fid = ?", undef, $wrong_devcount, $info->{fid}), 1, "set improper devcount");

        $info = $mogc->file_info($key);
        is($info->{devcount}, $wrong_devcount, "devcount is set to $wrong_devcount");

        full_fsck($tmptrack, $dbh);

        do {
            $info = $mogc->file_info($key);
        } while ($info->{devcount} == $wrong_devcount && sleep(0.1));
        is($info->{devcount}, 2, "devcount is corrected by fsck");

        # XXX POVI gets logged here, but BCNT might be more correct...
        wait_for_empty_queue("file_to_queue", $dbh);
        @fsck_log = $sto->fsck_log_rows;
        is($fsck_log[0]->{evcode}, "POVI", "policy violation logged");
    }
}

# nuke a file from disk but keep the file_on row
{
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 2, "two paths returned from get_paths");
    $rv = $ua->delete($paths[0]);
    ok($rv->is_success, "DELETE successful");

    full_fsck($tmptrack, $dbh);
    do {
        @fsck_log = $sto->fsck_log_rows;
    } while (scalar(@fsck_log) < 2 && sleep(0.1));

    my $miss = $fsck_log[0];
    is($miss->{evcode}, "MISS", "missing file logged by fsck");

    my $repl = $fsck_log[1];
    is($repl->{evcode}, "REPL", "replication request logged by fsck");

    wait_for_empty_queue("file_to_replicate", $dbh);

    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 2, "two paths returned from get_paths");
    foreach my $path (@paths) {
        $rv = $ua->get($path);
        is($rv->content, "hello\n", "GET successful on restored path");
    }
}

# change the length of a file from disk and have fsck correct it
{
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 2, "two paths returned from get_paths");
    $req = HTTP::Request->new(PUT => $paths[0]);
    $req->content("hello\r\n");
    $rv = $ua->request($req);
    ok($rv->is_success, "PUT successful");

    full_fsck($tmptrack, $dbh);
    do {
        @fsck_log = $sto->fsck_log_rows;
    } while (scalar(@fsck_log) < 2 && sleep(0.1));

    my $blen = $fsck_log[0];
    is($blen->{evcode}, "BLEN", "missing file logged by fsck");

    my $repl = $fsck_log[1];
    is($repl->{evcode}, "REPL", "replication request logged by fsck");

    wait_for_empty_queue("file_to_replicate", $dbh);

    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 2, "two paths returned from get_paths");
    foreach my $path (@paths) {
        $rv = $ua->get($path);
        is($rv->content, "hello\n", "GET successful on restored path");
    }
}

# nuke a file completely and irreparably
{
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 2, "two paths returned from get_paths");
    foreach my $path (@paths) {
        $rv = $ua->delete($path);
        ok($rv->is_success, "DELETE successful");
    }

    full_fsck($tmptrack, $dbh);
    do {
        @fsck_log = $sto->fsck_log_rows;
    } while (scalar(@fsck_log) < 4 && sleep(0.1));

    is($fsck_log[0]->{evcode}, "MISS", "missing file logged for first path");
    is($fsck_log[1]->{evcode}, "MISS", "missing file logged for second path");
    is($fsck_log[2]->{evcode}, "SRCH", "desperate search attempt logged");
    is($fsck_log[3]->{evcode}, "GONE", "inability to fix FID logged");

    wait_for_empty_queue("file_to_queue", $dbh);
    $info = $mogc->file_info($key);

    # XXX devcount probably needs to be updated on GONE
    # is($info->{devcount}, 2, "devcount updated to zero");
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 0, "get_paths returns nothing");
}

done_testing();
