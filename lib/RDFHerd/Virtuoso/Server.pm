# Virtuoso Server Object
#
# Copyright © 2008-2010  Creative Commons Corp.
#
# $Id: Server.pm 3580 2010-08-18 22:51:54Z bawden $

package RDFHerd::Virtuoso::Server;

use 5.008_005;
use strict;
use integer;
use Carp;
use Cwd qw(abs_path getcwd);
use DBI;
use English '-no_match_vars';
use Fcntl qw(O_RDONLY);
use FileHandle;
use POSIX qw(mkfifo EEXIST);
use RDFHerd::Server;
use RDFHerd::Utils qw(check_class_version site_config
		      full_hostname hash_compose mjdtime
		      erase_file evacuate_directory directory_is_empty
		      yes_or_no password_read exit_check);
use RDFHerd::Virtuoso::IniFile;

our (@ISA, $VERSION);
@ISA = qw(RDFHerd::Server);
$VERSION = 1.18_01;

my $builtin_cfg = {
    install_dir => "/usr/local",
    bin_dir => "install/bin",
    lib_dir => "install/lib",
    virtuoso_dir => "install/var/lib/virtuoso",
    http_server_dir => "server/http_server",
    vad_dir => "install/share/virtuoso/vad",
    plugin_dir => "lib/virtuoso/hosting",
    executable => "bin/virtuoso-t",
    ini_tool => "bin/inifile",
    ini_template => "virtuoso/db/virtuoso.ini",
    odbc_driver => "lib/virtodbc.so",
    output_file => "/dev/null",
    striping => 0,
    segment_count => 5,
    segment_size => "1G",
    stripe_dirs => ["/db1", "/db2"],
    result_set_max_rows => 2_000_000_000,
    plugins => [],
    host => full_hostname(),
};

sub _new {
    my ($class, $class_name, $path, $server_cfg) = @_;
    check_class_version(1, 3, $path, $server_cfg);
    my $name = (split('/', $path))[-1];
    $name or die "Can't use the root directory: $path\n";
    for my $param (qw(http_port sql_port)) {
	unless ($server_cfg->{$param}) {
	    die "$param not defined properly in $path\n";
	}
    }
    # The layout of the server dir itself is not something the user can
    # control -- we put it in the same cfg table only for convenience.
    my $override_cfg = {
	name => $name,
	server_dir => $path,
	ini_file => "server/virtuoso.ini",
	odbc_ini_file => "server/odbc.ini",
	fifo_file => "server/FIFO",
    };
    my $defaults_cfg = site_config("virtuoso_"
				   . ($server_cfg->{defaults} || "default")
				   . "_defaults");
    my $cfg = hash_compose($override_cfg,
			   $server_cfg,
			   $defaults_cfg,
			   $builtin_cfg);
    # XXX this option stuff isn't Virtuoso specific...
    my $system_pid_file = 0;
    my $opt_noquestions = 0;
    my $opt_all = 0;
    my $self = {
	class_name => "Virtuoso Server",
	path => $path,
	config => $cfg,
	state_file => "$path/State",
	state_mode => 'CLOSE',
	system_pid_file => \$system_pid_file,
	opt_noquestions => \$opt_noquestions,
	opt_all => \$opt_all,
	# There is apparently a 31 character limit on database names.  Who
	# the hell knows what layer in the DBI/ODBC/Virtuoso stack that
	# comes from...
	odbc_id => sprintf("%.30s", $cfg->{sql_port} . '@' . $cfg->{host}),
    };
    bless($self, $class);
    return $self;
}

# (Emacs 21.3 is driven totally mad by the syntax of the following
# definition.  Don't waste your time fighting with it...)
sub command_table {
    my ($self) = @_;
    return hash_compose({
	configure => {
	    proc => \&cmd_configure,
	    doc => <<EOF
Update the server\'s configuration file from its Config.pl file.  This will
-not- happen automatically whenever the Config.pl file changes.  (Because you
might want to maintain the configuration file manually!)
EOF
	},
	start => {
	    proc => \&cmd_start,
	    usage => "[--pidfile <path>]",
	    options => {
		"pidfile=s" => $self->{system_pid_file},
	    },
	    doc => <<EOF
Start the server.  If --pidfile is specified, the server\'s process ID will be
stored in <path>.
EOF
	},
	database_clear => {
	    proc => \&cmd_database_clear,
	    usage => "[--noquestions]",
	    options => {
		"noquestions" => $self->{opt_noquestions},
	    },
	    doc => <<EOF
Delete the entire contents of the database.  This will delete all of the
server\'s files from the filesystem.

If --noquestions is specified, the user will not be asked to confirm the
operation.
EOF
	},
	database_save => {
	    proc => \&cmd_database_save,
	    usage => "[--noquestions] <backup_image_dir>",
	    options => {
		"noquestions" => $self->{opt_noquestions},
	    },
	    args => 1,
	    doc => <<EOF
Save the database into a backup image.

This clears the server\'s backup context and performs a full dump of the
database -- starting a new backup series.  You will no longer be able to
extend any previous backup series this server may have been keeping.

If --noquestions is specified, the user will not be asked to confirm the
operation.
EOF
	},
	database_restore => {
	    proc => \&cmd_database_restore,
	    usage => "<backup_image_dir>",
	    args => 1,
	    doc => <<EOF
Restore the database from a saved backup image.

You must stop the server and clear the database before using this command.
EOF
	}
    }, $self->SUPER::command_table);
}

#
# Configuration
#

my @tunables
    = (
       ["max_checkpoint_remap", "Database", "MaxCheckpointRemap"],
       ["striping", "Database", "Striping"],
       ["file_extend", "Database", "FileExtend"],
       ["server_threads", "Parameters", "ServerThreads"],
       ["number_of_buffers", "Parameters", "NumberOfBuffers"],
       ["max_dirty_buffers", "Parameters", "MaxDirtyBuffers"],
       ["lock_in_mem", "Parameters", "LockInMem"],
       ["transaction_after_image_limit", "Parameters", "TransactionAfterImageLimit"],
       ["execution_timeout", "SPARQL", "ExecutionTimeout"],
       ["max_query_execution_time", "SPARQL", "MaxQueryExecutionTime"],
       ["max_query_cost_estimation_time", "SPARQL", "MaxQueryCostEstimationTime"],
       ["result_set_max_rows", "SPARQL", "ResultSetMaxRows"],
       ["trace_on","Parameters", "TraceOn"],
       ["syslog", "Database", "Syslog"],
       ["http_threads", "HTTPServer", "ServerThreads"],
       ["http_port", "HTTPServer", "ServerPort"],
       ["sql_port", "Parameters", "ServerPort"],
       ["fds_per_file", "Parameters", "FDsPerFile"],
       ["default_isolation", "Parameters", "DefaultIsolation"],
       ["stop_compiler_when_x_over_run_time", "Parameters", "StopCompilerWhenXOverRunTime"],
       );

my @paths
    = (
       ["vad_dir", "Parameters", "VADInstallDir"],
       ["http_server_dir", "HTTPServer", "ServerRoot"],
       ["plugin_dir", "Plugins", "LoadPath"],
       );

my @make_directories = (
    "http_server",
    "http_server/root",
    "http_server/root/conductor",	# so directory index looks good
    "http_server/root/notices",
    "http_server/root/sparql",		# so directory index looks good
    );

sub cmd_configure {
    my ($self) = @_;

    $self->check_uid_write;

    my $ini =
	new RDFHerd::Virtuoso::IniFile($self->config_path("ini_tool"),
				       $self->config_path("ini_file"),
				       $self->config_path("ini_template"));
    for my $entry (@tunables) {
	my ($var, $section, $key) = @{$entry};
	my $val = $self->config->{$var};
	if (defined($val)) {
	    $ini->put($section, $key, $val);
	}
    }
    for my $entry (@paths) {
	my ($var, $section, $key) = @{$entry};
	my $val = $self->config_path($var);
	if (defined($val)) {
	    $ini->put($section, $key, $val);
	}
    }
    
    my $name = $self->config_string("name");
    my $host = $self->config_string("host");
    my $http_port = $self->config_string("http_port");
    my $server_dir = $self->config_path("server_dir");
    my $bundle_dir = $self->config_path("bundle_dir");

    my $server_name = "virtuoso-$name-$host";
    $ini->put("Replication", "ServerName", $server_name);
    $ini->put("Zero Config", "ServerName", $server_name);

    $ini->put("URIQA", "DefaultHost", "$host:$http_port");

    my $dirs = $self->config_path("vad_dir");
    $dirs = $server_dir . ", " . $dirs;
    $dirs = $bundle_dir . ", " . $dirs;
    if (defined($self->config->{load_dir})) {
	$dirs = $self->config_path("load_dir") . ", " . $dirs;
    }
    $ini->put("Parameters", "DirsAllowed", $dirs);

    my $count = $self->config_string("segment_count");
    my $size = $self->config_string("segment_size");
    my $sdirs = $self->config->{stripe_dirs};
    my $i = 0;
    my @dirs = ();
    while ($i++ < $count) {
	my $val = $size;
	my $q = 0;
	for my $dir (@{$sdirs}) {
	    $val .= sprintf(", %s/%s/%04d.db = q%d", $dir, $name, $i, $q);
	    $q++;
	}
	push(@dirs, $val);
    }
    $ini->write_array("Striping", "Segment", \@dirs);

    $ini->write_array("Plugins", "Load", $self->config->{plugins});

    # If striping is enabled, create stripe dirs if they don't already exist.
    if ($self->config->{striping}) {
	for my $dir (@$sdirs) {
	    unless (-d "$dir/$name") {
		if (-e "$dir/$name") {
		    warn "$dir/$name exists, but isn't a directory...\n";
		} else {
		    mkdir("$dir/$name", 0777) or
			warn "$ERRNO: creating $dir/$name/ -- Please" .
			" create this directory\nmanually, and make sure" .
			" the server has write access.\n";
		}
	    }
	}
    }

    # Create directory structure:
    for my $mkdir (@make_directories) {
	mkdir("$server_dir/$mkdir", 0777) or
	    ($ERRNO == EEXIST) or
	    die "$ERRNO: creating directory: $mkdir\n";
    }

    # (Re)create the ODBC init file:
    my $odbc_ini_file = $self->config_path("odbc_ini_file");
    my $odbc_id = $self->{odbc_id};
    my $sql_port = $self->config_string("sql_port");
    my $odbc_driver = $self->config_path("odbc_driver");
    open(ODBC, ">", $odbc_ini_file) or die;
    ### Doesn't seem to be needed by anything we care about:
    # print ODBC "[ODBC Data Sources]\n$odbc_id = Virtuoso $name\n\n";
    print ODBC "[$odbc_id]\n";
    print ODBC "Description = Virtuoso $name\n";
    print ODBC "Driver      = $odbc_driver\n";
    print ODBC "Address     = $host:$sql_port\n";
    close(ODBC);

    # Create a link to the bundle directory for the HTTP server:
    my $bundle_link = "$server_dir/http_server/bundle";
    if (-e $bundle_link) {
	if (-l $bundle_link) {
	    unlink($bundle_link) or
		die "$ERRNO: deleting link: $bundle_link\n";
	} else {
	    die "A non-link is in the way: $bundle_link\n";
	}
    }
    symlink($bundle_dir, $bundle_link) or
	die "$ERRNO: creating link: $bundle_link -> $bundle_dir\n"; 

    # Finally, create a FIFO for feeding the server:
    my $fifo = $self->config_path("fifo_file");
    unless (-p $fifo) {
	if (-e $fifo) {
	    die "Not a named pipe: $fifo\n";
	}
	mkfifo($fifo, 0660) or
	    die "$ERRNO: mkfifo()\n";
    }

    'OK';
}

sub cmd_database_clear {
    my ($self) = @_;
    $self->check_uid_write;
    unless ($self->status) {
	die "You must stop the server before clearing the database.\n";
    }
    my $noquestions_ptr = $self->{opt_noquestions};
    unless ($$noquestions_ptr or
	    yes_or_no("Are you sure you want to erase the contents of the database?")) {
	exit 1;
    }
    my $name = $self->config_string("name");
    my $server_dir = $self->config_path("server_dir");
    for my $entry (
		   "virtuoso-temp.db",
		   "virtuoso-temp.trx",
		   "virtuoso.db",
		   "virtuoso.lck",
		   "virtuoso.log",
		   "virtuoso.pxa",
		   "virtuoso.trx",
		   ) {
	erase_file("$server_dir/$entry");
    }
    if ($self->config->{striping}) {
	my $stripe_dirs = $self->config->{stripe_dirs};
	for my $dir (@$stripe_dirs) {
	    if (-d "$dir/$name") {
		evacuate_directory("$dir/$name");
	    }
	}
    }
    $self->load_db_erase();
    # Actually, this was a bad idea:
    #erase_file($self->config_path("ini_file"));
    $self->state_clear();
    'OK'
}

sub cmd_database_save {
    my ($self, undef, $dst) = @_;
    $self->check_uid_write;
    unless ($self->status == 0) {
	die "The server must be running in order to do backups.\n";
    }
    my $noquestions_ptr = $self->{opt_noquestions};
    unless ($$noquestions_ptr or
	    yes_or_no("Are you sure you want to start a new backup series?")) {
	exit 1;
    }
    my $server_dir = $self->config_path("server_dir");
    (-d $dst) &&
	(directory_is_empty($dst)) or
	die "$dst is not an empty directory.\n";

    $dst = abs_path($dst);
    erase_file("$server_dir/Backup");
    symlink($dst, "$server_dir/Backup") or
	die "$ERRNO: creating link $server_dir/Backup\n";

    if (my $err = $self->open_connection()) { die "$err\n"; }
    my $dbh = $self->{dbh} or die;
    $dbh->do(q{backup_context_clear()}) or die $dbh->errstr;
    $dbh->do(q{backup_online('Backup/backup_', 100000)}) or
	die $dbh->errstr;
    $self->close_connection();
    
    $self->load_db_save("$server_dir/Backup/load_db.log") or
	die "$ERRNO: saving the load metadata.\n";

    'OK'
}

sub cmd_database_restore {
    my ($self, undef, $src) = @_;
    $self->check_uid_write;
    unless ($self->status) {
	die "You must stop the server and clear the database before restoring.\n";
    }
    my $server_dir = $self->config_path("server_dir");
    if (-e "$server_dir/virtuoso.log") {
	die "You must clear the database before restoring.\n";
    }
    my $executable = $self->config_path("executable");
    (-x $executable) or die "I can't seem to execute $executable\n";
    my $ini_file = $self->config_path("ini_file");
    (-r $ini_file) or die "I can't seem to read $ini_file\n";

    (-d $src) &&
	(-e "$src/load_db.log") &&
	(-e "$src/backup_1.bp") or
	die "$src does not look like a directory containing a backup image.\n";

    $src = abs_path($src);
    erase_file("$server_dir/Backup");
    symlink($src, "$server_dir/Backup") or
	die "$ERRNO: creating link $server_dir/Backup\n";

    my $old_dir = getcwd();
    chdir($server_dir) or
	die "Can't cd to $server_dir: $ERRNO\n";
    # Unfortunately, the exit code from virtuoso is 0 even if this fails:
    system($executable, "+configfile", $ini_file,
	   "+restore-backup", "Backup/backup_") or
	       exit_check($executable);
    chdir($old_dir) or
	die "Can't cd back to $old_dir: $ERRNO\n";

    $self->load_db_restore("$server_dir/Backup/load_db.log") or
	die "$ERRNO: restoring the load metadata.\n";

    'OK'
}

sub cmd_start {
    my ($self) = @_;

    $self->check_uid_write;

    return 'OK' if ($self->status == 0);

    my $dir = $self->config_path("server_dir");
    my $executable = $self->config_path("executable");
    my $ini_file = $self->config_path("ini_file");
    my $output_file = $self->config_path("output_file");

    (-x $executable) or die "I can't seem to execute $executable\n";
    (-r $ini_file) or die "I can't seem to read $ini_file\n";

    $self->state_close;		# Close before we fork, just in case.

    local $SIG{CHLD} = 'IGNORE';	# No waiting...
    
    my $pid = fork();
    defined($pid) or die "$ERRNO: fork()\n";

    # Server process:
    if ($pid == 0) {
	chdir($dir) or die "Can't cd to $dir: $ERRNO\n";
	open(SAVED, ">&STDERR") or die;
	open(STDOUT, ">", $output_file) or die;
	open(STDERR, ">&STDOUT") or die;
	exec($executable, "+foreground", "+configfile", $ini_file)
	    or 0;		# prevent warning
	# Unfortunately, errno is lost because STDERR was redirected...
	print SAVED "Failed to exec $executable\n";
	exit(0);
    }

    sleep(3);
    (1 == kill(0, $pid)) or die "Server failed to start?\n";
	
    $self->state_write("pid", $pid);

    my $ptr_system_pid_file = $self->{system_pid_file};
    my $system_pid_file = $$ptr_system_pid_file;
    if ($system_pid_file) {
	open(PID, ">", $system_pid_file)
	    or die "$ERRNO: opening $system_pid_file\n";
	print PID "$pid\n";
	close(PID);
    }
    
    'OK';
}

sub pid {
    return $_[0]->state_read("pid") || -1;
}

sub rm_pid {
    my ($self) = @_;
    $self->state_delete("pid");
}

# Virtuoso version numbers seen in the wild:
#
#	Internal	Public
#	04.50.2919
#	05.00.3003
#	05.00.3008
#	05.00.3009	5.0.0
#	05.00.3010
#	05.00.3011
#	05.00.3012
#	05.00.3018	5.0.2
#	05.00.3023	5.0.3
#			5.0.4
#	05.00.3026	5.0.5
#	05.00.3028	5.0.6
#	05.00.3032	5.0.7 I<and> 20080730
#	05.00.3033	20080808
#	05.08.3034	5.0.8
#	05.09.3036	5.0.9
#	05.10.3037	5.0.10
#	05.11.3039	5.0.11
#	05.11.3040	20090916
#	05.12.3041	5.0.12 I<and> 5.0.13
#	05.14.3041	5.0.14
#	06.00.3118	6.0.0-tp1
#	06.00.3122	(special release for us)
#	06.00.3123	6.0.0
#	06.01.3126	6.1.0
#	06.01.3127	6.1.1

# We canonicalize these version number triples into strings that can be
# compared in alphabetical order:
use constant {
    VIRTUOSO_5_0_8	=> "000005 000008 003034",
    VIRTUOSO_5_0_12	=> "000005 000012 003041",
    VIRTUOSO_6_1_0	=> "000006 000001 003126",
#    VIRTUOSO_6_1_1	=> "000006 000001 003127",
};

# Method I<and> subroutine:
sub canonicalize_server_version ($$) {
    (@_ == 2) or confess "\tBUG";
    my (undef, $version) = @_;
    my ($a, $b, $c) = ($version =~ m(^(\d+)\.(\d+)\.(\d+)\z));
    if (!defined($c) or
	$a > 999999 or $a < 4 or
	$b > 999999 or
	$c > 999999 or $c < 2919) {
	die "Can't interpret server version: $version\n";
    }
    return sprintf("%06d %06d %06d", $a, $b, $c);
}

sub server_name { "Virtuoso" }
sub server_version { $_[0]->{server_version} }

# In theory, we shouldn't have to do this nonsense of creating our own
# odbc.ini file.  A source name that looks something like
# "DBI:ODBC:driver=..;host=...;port=..." should be all that is needed.
# That's a very nice theory.  If there was documentation that described
# what attributes were expected by the driver, maybe I we could make that
# work.  But I'm tired of playing guessing games and reading source code.
# We're lucky to have found out about the (undocumented as far as I can
# tell) ODBCINI environment variable.  This works.

sub open_connection {
    my ($self, %attrs) = @_;

    # Setting AutoCommit to 1 for now, because nothing we currently do
    # requires larger transactions, and this might save some resources in
    # the server.  XXX keep thinking about this...

    # Default: PrintError => 0, AutoCommit => 1
    $attrs{PrintError} = 0 unless (exists($attrs{PrintError}));
    $attrs{AutoCommit} = 1 unless (exists($attrs{AutoCommit}));

    if ($self->{dbh}) {
	confess "Database connection already open?\n\tBUG";
    }

    $self->load_password("Password for");
    my $user = $self->config_string("virtuoso_user");
    my $pass = $self->{virtuoso_password};

    my $odbc_id = $self->{odbc_id};
    my $odbc_ini_file = $self->config_path("odbc_ini_file");
    local $ENV{ODBCINI} = $odbc_ini_file;
    my $dbh;
    for (;;) {
	$dbh = DBI->connect("DBI:ODBC:$odbc_id", $user, $pass, \%attrs);
	last if ($dbh);
	return DBI::errstr if (DBI::errstr !~ m'CL033: Connect failed to ');
	print STDERR "Connection to server failed -- waiting...\n";
	sleep(5);
    }
    $self->{dbh} = $dbh;
    $self->{server_version} =
	canonicalize_server_version($self, $dbh->get_info(18));
    my $load_threads = $self->config->{load_threads};
    unless (defined($load_threads)) {
	# XXX why times 4?  Because on our 4-core machine, 12 threads
	# worked pretty well...  But it's just a guess:
	$load_threads = ($self->config_string("cpu_cores") - 1) * 4;
    }
    if ($load_threads < 1) { $load_threads = 1 }
    $self->{load_threads} = $load_threads;
    return 0;
}

sub close_connection {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    unless ($dbh) {
	confess "Database connection not open?\n\tBUG";
    }
    $self->commit();
    $dbh->disconnect() or die $dbh->errstr;
    $self->{dbh} = 0;
}

sub commit {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    # If we never opened a connection, then there is nothing to commit!
    if ($dbh) {
	$dbh->{AutoCommit} or
	    $dbh->commit() or
	    die $dbh->errstr;
    }
}

sub checkpoint {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    # If we never opened a connection, then there is nothing to checkpoint!
    if ($dbh) {
	$dbh->do(q{checkpoint}) or die $dbh->errstr;
    }
}

sub load_password {
    (@_ == 2) or confess "\tBUG";
    my ($self, $password_for) = @_;
    my $user = $self->config_string("virtuoso_user");
    my $pass = $self->{virtuoso_password};
    unless (defined($pass)) {
	if (exists($ENV{RDFHERD_SERVER_PASSWORD})) {
	    $pass = $ENV{RDFHERD_SERVER_PASSWORD};
	} else {
	    $pass = password_read("$password_for Virtuoso user \"$user\"");
	}
	$self->{virtuoso_password} = $pass;
    }
}

sub change_password {
    (@_ == 2) or confess "\tBUG";
    my ($self, $new_pass) = @_;
    my $user = $self->config_string("virtuoso_user");
    my $old_pass = $self->{virtuoso_password};
    unless (defined($old_pass)) {
	confess "Missing old password?\n\tBUG";
    }
    my $dbh = $self->{dbh};
    unless ($dbh) {
	confess "Database connection not open?\n\tBUG";
    }
    $dbh->do(q{USER_CHANGE_PASSWORD(?, ?, ?)}, {},
	$user, $old_pass, $new_pass) or
	    die $dbh->errstr;
    $self->{virtuoso_password} = $new_pass;
}

my %load_table = (
    rdf		=> \&_load_plain_file,
    rdfbz	=> \&_load_compressed_file,
    rdfgz	=> \&_load_compressed_file,
    ttl		=> \&_load_plain_file,
    ttlbz	=> \&_load_compressed_file,
    ttlgz	=> \&_load_compressed_file,
    script	=> \&_load_script_file,
    sparql	=> \&_load_sparql_file,
    sql		=> \&_load_sql_file,
    );

sub load_file {
    (@_ == 5) or confess "\tBUG";
    my ($self, $type, $path, $graph, $base) = @_;
    my $proc = $load_table{$type};
    (defined($proc)) or die "unsupported file type: $path\n";
    my $dbh = $self->{dbh};
    unless ($dbh) {
	confess "Database connection not open?\n\tBUG";
    }
    &$proc($self, $dbh, $type, $path, $graph, $base);
}

my %st_table = (
    rdf		=> q{
	DB.DBA.RDF_LOAD_RDFXML_MT(file_to_string_output(?), ?, ?, 1, %d)
    },
    rdfbz	=> q{
	DB.DBA.RDF_LOAD_RDFXML_MT(file_to_string_output(?, 0, -1), ?, ?, 1, %d)
    },
    rdfgz	=> q{
	DB.DBA.RDF_LOAD_RDFXML_MT(file_to_string_output(?, 0, -1), ?, ?, 1, %d)
    },
    ttl		=> q{
	DB.DBA.TTLP_MT(file_to_string_output(?), ?, ?, 0, 1, %d)
    },
    ttlbz	=> q{
	DB.DBA.TTLP_MT(file_to_string_output(?, 0, -1), ?, ?, 0, 1, %d)
    },
    ttlgz	=> q{
	DB.DBA.TTLP_MT(file_to_string_output(?, 0, -1), ?, ?, 0, 1, %d)
    },
    );

sub _load_file ($$$$$$$) {
    my ($server, $dbh, $type, $errpath, $path, $graph, $base) = @_;

    $dbh->do(q{log_enable(2)}) or die $dbh->errstr;

    # Use "%d" for integers.  Use "?" for strings...
    my $cmd = sprintf($st_table{$type}, $server->{load_threads});
    $dbh->do($cmd, {}, $path, $base, $graph) or
	die("Error:\n    ",
	    $dbh->errstr,
	    "\nwhile loading:\n    $errpath\n");

    $dbh->do(q{log_enable(1)}) or die $dbh->errstr;
}

sub _load_plain_file {
    my ($server, $dbh, $type, $path, $graph, $base) = @_;
    _load_file($server, $dbh, $type, $path, $path, $graph, $base);
}

my %zcat_table = (
    rdfbz	=> "bzip2 -d -q -c",
    rdfgz	=> "gzip -d -q -c",
    ttlbz	=> "bzip2 -d -q -c",
    ttlgz	=> "gzip -d -q -c",
    );

sub _load_compressed_file {
    my ($server, $dbh, $type, $path, $graph, $base) = @_;
    ($server->config->{file_to_string_patch})
	or ($server->{server_version} ge VIRTUOSO_5_0_12)
	or die <<"EOM"
This version of RDFHerd requires that you apply the file_to_string patch to
Virtuoso.  If your Virtuoso has in fact been patched, you need to set
file_to_string_patch in your server config file.
EOM
;
    my $fifo = $server->config_path("fifo_file");
    my $zcat = $zcat_table{$type};
    defined($zcat) or confess "\tBUG";
    # XXX will this rendezvous correctly in all cases?
    system("$zcat \Q$path\E > \Q$fifo\E &"); # Yuck!
    # XXX check for the patch and use a temporary?
    _load_file($server, $dbh, $type, $path, $fifo, $graph, $base);
}

sub _sql_error ($$) {
    my ($dbh, $command) = @_;
    if (length($command) > 500) {
	$command = substr($command, 0, 400) . "...";
    }
    die("Error:\n    ",
	$dbh->errstr,
	"\nwhile executing SQL:\n    $command\n");
}

sub _sql_execute ($$) {
    my ($dbh, $command) = @_;
    # print STDERR "-- execute --\n$command\n-------------\n";
    $dbh->do(q{log_enable(2)}) or die $dbh->errstr;
    my $rv = $dbh->do($command) or _sql_error($dbh, $command);
    $dbh->do(q{log_enable(1)}) or die $dbh->errstr;
}

sub _load_sql_file {
    my ($server, $dbh, $type, $path, $graph, $base) = @_;
    my $fh = new FileHandle;
    $fh->open($path, O_RDONLY) or
	die "$ERRNO: opening $path\n";
    my $command = "";
    while (my $line = $fh->getline) {
	if ($line eq ";\n") {
	    _sql_execute($dbh, $command);
	    $command = "";
	} else {
	    $command .= $line;
	}
    }
    if ($command) {
	warn "Extra lines ignored at the end of $path";
    }
    $fh->close();
}

sub _load_sparql_file {
    my ($server, $dbh, $type, $path, $graph, $base) = @_;
    my $fh = new FileHandle;
    $fh->open($path, O_RDONLY) or
	die "$ERRNO: opening $path\n";
    _sql_execute($dbh, join('', "sparql\n", $fh->getlines));
    $fh->close();
}

sub clear_graph {
    (@_ == 2) or confess "\tBUG";
    my ($self, $graph) = @_;
    my $dbh = $self->{dbh};
    unless ($dbh) {
	confess "Database connection not open?\n\tBUG";
    }
    _sql_execute($dbh, qq{sparql
	delete from graph <$graph> {?s ?p ?o} 
	from <$graph>
	where {?s ?p ?o}});
}

# A lot of this is not specific to Virtuoso, and should be lifted into
# RDFHerd::Server or RDFHerd::Bundle or RDFHerd::Utils...

my %script_table = (
    comment		=> sub {},
    might_err		=> \&_do_might_err,
    if			=> \&_do_test,
    ifnot		=> \&_do_test,
    sparql		=> \&_do_sparql,
# XXX See comment before _do_sparql_fetch
#   sparql_fetch	=> \&_do_sparql_fetch,
    sparql_definitions	=> \&_do_sparql_definitions,
    sql			=> \&_do_sql,
    sql_fetch		=> \&_do_sql_fetch,
    );

sub _load_script_file {
    my ($server, $dbh, $type, $path, $graph, $base) = @_;
    my $fh = new FileHandle;
    $fh->open($path, O_RDONLY) or
	die "$ERRNO: opening $path\n";
    my $head = "#>comment";
    my $body = "";
    my @pairs = ();
    while (my $line = $fh->getline) {
	chomp $line;
	if ($line =~ m(^\#>)) {
	    push(@pairs, [$head, $body]);
	    $head = $line;
	    $body = "";
	} elsif ($line =~ m(^\s*(\#|\z))) {
	    # discard comments and empty lines
	} else {
	    $body .= $line . "\n";
	}
    }
    push(@pairs, [$head, $body]);
    $fh->close();
    my $debug_scripts = $server->config->{debug_scripts};
    my $state = {
	server => $server,
	dbh => $dbh,
	debug_scripts => $debug_scripts,
	pairs => \@pairs,
	# The rest are not actually used:
	type => $type,
	path => $path,
	graph => $graph,
	base => $base,
	};
    my ($pair, $op, $proc);
    while (@pairs) {
	$pair = shift(@pairs);
	$head = $pair->[0];
	$body = $pair->[1];
	unless (($op) = ($head =~ m(^\#>\s*(\w+)(\s|\z)))) {
	    die "Bad script control line: \"$head\"\n";
	}
	$proc = $script_table{lc($op)};
	unless ($proc) {
	    die "Unknown operator: $op in \"$head\"\n";
	}
	if ($debug_scripts) {
	    my ($d, $m) = mjdtime();
	    print STDOUT "[$head T=$d/$m]\n$body";
	}
	&$proc($head, $body, $state);
    }
    if ($debug_scripts) {
	my ($d, $m) = mjdtime();
	print STDOUT "[Done T=$d/$m]\n";
    }
}

sub _clear ($) {
    my ($state) = @_;
    $state->{dont_run} = 0;
    $state->{might_err} = 0;
}

sub _dont_run ($) {
    my ($state) = @_;
    if ($state->{dont_run}) {
	if ($state->{debug_scripts}) {
	    print STDOUT "[^^SKIPPED^^]\n"; 
	}
	_clear($state);
	return 1;
    } else {
	return 0;
    }
}

sub _do_might_err {
    my ($head, $body, $state) = @_;
    $state->{might_err} = 1;
}

sub _do_test {
    my ($head, $body, $state) = @_;
    my ($op, $var);
    unless (($op, $var) = ($head =~ m(^\#>\s*(\w+)\s+(\w+)\s*\z))) {
	die "Bad script conditional: \"$head\"\n";
    }
    my $val = $state->{server}->config->{$var};
    $op = lc($op);
    if ($op eq 'if') {
	$state->{dont_run} = !$val;
    } elsif ($op eq 'ifnot') {
	$state->{dont_run} = $val;
    } else {
	confess "\tBUG";
    }
}

sub _do_sparql_definitions {
    my ($head, $body, $state) = @_;
    return if _dont_run($state);
    $state->{sparql_definitions} = $body;
    _clear($state);
}

sub _execute ($$) {
    my ($state, $command) = @_;
    my $dbh = $state->{dbh};
    $dbh->do(q{log_enable(2)}) or die $dbh->errstr;
    my $rv = $dbh->do($command);
    if (defined($rv)) {
	if ($state->{debug_scripts}) {
	    print STDOUT "[Modified $rv rows]\n";
	}
    } elsif ($state->{might_err}) {
	if ($state->{debug_scripts}) {
	    print STDOUT "[^^^FAILED^^^]\n";
	}
    } else {
	_sql_error($dbh, $command);
    }
    $dbh->do(q{log_enable(1)}) or die $dbh->errstr;
}

sub _do_sparql {
    my ($head, $body, $state) = @_;
    return if _dont_run($state);
    my $defs = $state->{sparql_definitions} || "";
    _execute($state, "sparql\n" . $defs . $body);
    _clear($state);
}

sub _do_sql {
    my ($head, $body, $state) = @_;
    return if _dont_run($state);
    _execute($state, $body);
    _clear($state);
}

sub _execute_fetch ($$) {
    my ($state, $command) = @_;
    my $dbh = $state->{dbh};
    $dbh->do(q{log_enable(2)}) or die $dbh->errstr;
    #my $sth = $dbh->prepare($command, {});
    my $rv = $dbh->selectall_arrayref($command);
    if (defined($rv)) {
	if ($state->{debug_scripts}) {
	    my $i = 0;
	    for my $row (@$rv) {
		print STDOUT sprintf("%4d:", $i);
		for my $val (@$row) {
		    unless (defined($val)) {
			$val = "<undef>";
		    }
		    print STDOUT " $val";
		}
		print STDOUT "\n";
		$i++;
	    }
	    print STDOUT "[Returned $i rows]\n";
	}
    } elsif ($state->{might_err}) {
	if ($state->{debug_scripts}) {
	    print STDOUT "[^^^FAILED^^^]\n";
	}
    } else {
	_sql_error($dbh, $command);
    }
    $dbh->do(q{log_enable(1)}) or die $dbh->errstr;
}

# XXX This doesn't actually work for some reason having to do with "?"
# being both heavily used by SPARQL and being used for SQL placeholders...
sub _do_sparql_fetch {
    my ($head, $body, $state) = @_;
    return if _dont_run($state);
    my $defs = $state->{sparql_definitions} || "";
    _execute_fetch($state, "sparql\n" . $defs . $body);
    _clear($state);
}

sub _do_sql_fetch {
    my ($head, $body, $state) = @_;
    return if _dont_run($state);
    _execute_fetch($state, $body);
    _clear($state);
}

# Convenience:
sub _sql_execute_list ($@) {
    my ($dbh, @list) = @_;
    for my $command (@list) {
	_sql_execute($dbh, $command);
    }
}

# Prior to version 6.1.0, Virtuoso shipped with DB.DBA.RDF_QUAD as GSPO
# with an OGPS index.  We want SPOG with indices that we will construct
# later.
#
# Starting in 6.1.0, Virtuoso ships as PSOG with indices POGS, GS, OP and
# SP.  For now, we do nothing until we see how this works out.
sub prepare_for_initial_load {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    unless ($dbh) {
	confess "Database connection not open?\n\tBUG";
    }
    my $version = $self->{server_version};
    if ($version lt VIRTUOSO_6_1_0) {
	# print STDERR "rebuilding RDF_QUAD\n";
	# Or maybe just: q{drop index DB.DBA.RDF_QUAD_OGPS DB.DBA.RDF_QUAD}
	_sql_execute($dbh,
		     q{create table DB.DBA.RDF_QUAD_NEW
			   (g iri_id_8, s iri_id_8, p iri_id_8, o any,
			    primary key (s, p, o, g))});
	# The following 'alter index' is a syntax error in older Virtuosos.
	# It works in 5.0.8 (and maybe earlier).
	if ($version ge VIRTUOSO_5_0_8) {
	    print STDERR "XXX with partition step\n";
	    _sql_execute($dbh,
			 q{alter index RDF_QUAD_NEW
			       on DB.DBA.RDF_QUAD_NEW
			       partition (s int (0hexffff00))});
	}
	_sql_execute_list($dbh,
			  q{insert into DB.DBA.RDF_QUAD_NEW (g, s, p, o)
				select g, s, p, o from DB.DBA.RDF_QUAD},
			  q{drop table DB.DBA.RDF_QUAD},
			  q{alter table DB.DBA.RDF_QUAD_NEW
				rename DB.DBA.RDF_QUAD},
			  q{DB.DBA.RDF_CREATE_SPARQL_ROLES()});
    } else {
	# print STDERR "NOT rebuilding RDF_QUAD\n";
    }
    _sql_execute_list($dbh,
		      # XXX OK to run as dba?
		      q{VHOST_DEFINE(lpath=>'/',
				     ppath=>'/root/',
				     def_page=>'index.html',
				     is_brws=>1,
				     vsp_user=>'dba')},
		      # XXX OK to run as dba?
		      # This is so that we don't rely on the definition of
		      # '/' just given.
		      q{VHOST_DEFINE(lpath=>'/notices',
				     ppath=>'/root/notices/',
				     def_page=>'index.html',
				     is_brws=>1,
				     vsp_user=>'dba')},
	);
}

# This seemed potentially useful once:
#     q{create procedure COPY_RDF_QUAD_GRANTS () {
#	 for (select G_USER as g_user_old,
#		     G_OP as g_op_old,
#		     G_COL as g_col_old,
#		     G_GRANTOR as g_grantor_old,
#		     G_ADMIN_OPT as g_admin_opt_old
#	      from DB.DBA.SYS_GRANTS
#	      where G_OBJECT = 'DB.DBA.RDF_QUAD') do
#	  {
#	      insert soft DB.DBA.SYS_GRANTS (G_USER,
#					     G_OP,
#					     G_OBJECT,
#					     G_COL,
#					     G_GRANTOR,
#					     G_ADMIN_OPT)
#		  values (g_user_old,
#			  g_op_old,
#			  'DB.DBA.RDF_QUAD_NEW',
#			  g_col_old,
#			  g_grantor_old,
#			  g_admin_opt_old);
#	  }}},
	
1;
__END__

# Local Variables:
# mode: Perl
# End:
