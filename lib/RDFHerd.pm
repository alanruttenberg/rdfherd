# Object that are stored as file system directories.
#
# Copyright © 2008-2010  Creative Commons Corp.
#
# $Id: RDFHerd.pm 3580 2010-08-18 22:51:54Z bawden $

package RDFHerd;

use 5.008_005;
use strict;
use integer;
use Carp;
use Cwd qw(abs_path);
use English '-no_match_vars';
use RDFHerd::Utils qw(load_config make_constructor
		      get_config_string get_config_list
		      get_config_path get_config_ref
		      unsupported_interface
		      state_file_open state_file_close);

our (@ISA, $VERSION);
@ISA = qw();
$VERSION = 1.18_01;

my %classes = (
    rdf_bundle => "Bundle",
    # rdf_graph => "CTest",
    virtuoso_server => "Virtuoso/Server",
    test => "CTest",
    );

# Config file constructors are shared by all classes of RDFHerd objects
# because config files are parsed I<before> you discover what class of
# object you are dealing with.
my $config_bindings = {
    # For Bundle:
    File => make_constructor(['path'], [], [qw(graph base for type)],
			     CONSTRUCTOR => 'LOADSPEC'),
    Directory => make_constructor(['path'], [], [qw(graph base for)],
				  IS_DIR => 1,
				  CONSTRUCTOR => 'LOADSPEC'),
    Server => make_constructor(['name'], [], [qw(le lt ge gt eq ne)],
			       CONSTRUCTOR => 'LOADCONDITIONAL'),
};

my %cache = ();

# state modes
my %legal_mode = (SUPPORTED => 1, READ => 1, WRITE => 1, CLOSE => 1);

sub new {
    my (undef, $path) = @_;
    (-d $path) or die "Not a directory: $path\n";
    $path = abs_path($path);
    if (exists($cache{$path})) {
	return $cache{$path};
    }
    my $cpath = "$path/Config.pl";
    (-f $cpath) or die "Missing configuration: $cpath\n";
    my $cfg = load_config($cpath, $config_bindings);
    my $class_name = $cfg->{class} or die "No class specified: $cpath\n";
    $class_name = lc($class_name);
    $class_name =~ s([\W_]+)(_)g;
    (my $class = $classes{$class_name})
	or die "Unknown class \"$class_name\" in: $cpath\n";
    require "RDFHerd/$class.pm";
    $class =~ s(/)(::)g;
    my $self = "RDFHerd::$class"->_new($class_name, $path, $cfg);
    $cache{$path} = $self;
    $self->{class_name} ||= $class_name;
    $self->{path} ||= $path;
    $self->{config} ||= $cfg;
    if ($self->{state_file} || $self->{state_mode}) {
	$self->{state_file} ||= $self->{path} . "/State",
	$self->{state_mode} ||= 'CLOSE';
	$legal_mode{$self->{state_mode}} or confess "\tBUG";
    }
    $self->initialize();
    return $self;
}

sub class_name {
    my ($self) = @_;
    $self->{class_name} or confess "$self has no class_name?\n\tBUG";
}

sub path {
    my ($self) = @_;
    $self->{path} or confess "$self has no path?\n\tBUG";
}

sub config {
    my ($self) = @_;
    $self->{config} or confess "$self has no config?\n\tBUG";
}

sub config_string {
    @_ == 2 or confess "\tBUG";
    get_config_string($_[0]->config, $_[1]);
}

sub config_list {
    @_ == 2 or confess "\tBUG";
    get_config_list($_[0]->config, $_[1]);
}

sub config_ref {
    @_ == 3 or confess "\tBUG";
    get_config_ref($_[0]->config, $_[1], $_[2]);
}

sub config_path {
    @_ == 2 or confess "\tBUG";
    get_config_path($_[0]->config, $_[1]);
}

sub command_line_handler { 0 }
sub command_table { {} }

sub initialize {
    my ($self) = @_;
    my $user = $self->{config}->{require_user};
    $self->{read_only} = 0;
    if (defined($user)) {
	my $uid = $user;
	if ($user !~ m(^\d+\z)) {
	    $uid = getpwnam($user);
	    defined($uid) or die "Unknown required user: $user\n";
	}
	unless ($uid == $EUID) {
	    $self->{read_only} = "$user ($uid)";
	}
    }
}

sub check_uid {
    my ($self) = @_;
    my $ro = $self->{read_only};
    if ($ro) {
	die "You must be $ro to do that.\n";
    }
}

sub check_uid_write {
    my ($self) = @_;
    $self->check_uid;
    $self->state_lock;
}

# This is rarely what you want.  If you're only reading, there is usually
# no need to check the UID, either call ->state_lock_for_read or just start
# calling ->state_read().
sub check_uid_read {
    my ($self) = @_;
    $self->check_uid;
    $self->state_lock_for_read;
}

# Common slots

sub name {
    my ($self) = @_;
    $self->{name} or confess "$self has no name?\n\tBUG";
}

sub version {
    my ($self) = @_;
    $self->{version} or confess "$self has no version?\n\tBUG";
}

#
# State client interface
#

sub state_supported {
    @_ == 1 or confess "\tBUG";
    $_[0]->state_mode('SUPPORTED');
}

sub state_close {
    @_ == 1 or confess "\tBUG";
    $_[0]->state_mode('CLOSE');
}

sub state_read {
    @_ == 2 or confess "\tBUG";
    $_[0]->state_mode('READ')->{$_[1]};
}

sub state_lock_for_read {
    @_ == 1 or confess "\tBUG";
    $_[0]->state_mode('READ');
}

sub state_write {
    @_ == 3 or confess "\tBUG";
    $_[0]->state_mode('WRITE')->{$_[1]} = $_[2];
}

sub state_lock {
    @_ == 1 or confess "\tBUG";
    $_[0]->state_mode('WRITE');
}

sub state_delete {
    @_ == 2 or confess "\tBUG";
    delete($_[0]->state_mode('WRITE')->{$_[1]});
}

sub state_clear {
    @_ == 1 or confess "\tBUG";
    %{$_[0]->state_mode('WRITE')} = ();
}

sub state_foreach {
    @_ == 2 or confess "\tBUG";
    my ($self, $proc) = @_;
    my $tbl = $self->state_mode('READ');
    for my $key (keys(%$tbl)) {
	&$proc($self, $key, $tbl->{$key});
    }
}

#
# State provider interface
#

# Possible modes are SUPPORTED, READ, WRITE or CLOSE.  Others may follow
# someday.
sub state_mode {
    @_ == 2 or @_ == 3 or confess "\tBUG";
    my $self = shift;
    my $new_mode = shift;
    my $if_blocked = shift || 'DIE';
    $legal_mode{$new_mode} or confess "Bad state_mode: $new_mode\n\tBUG";
    my $old_mode = $self->{state_mode};
    if ($new_mode eq 'SUPPORTED') {
	return defined($old_mode);
    }
    defined($old_mode) or confess "Keeps no state: $self\n\tBUG";
    if ($new_mode eq 'CLOSE') {
	state_file_close($self);
	return 1;
    }
    if ($old_mode eq 'CLOSE') {
	return state_file_open($self, $new_mode, $if_blocked);
    }
    if ($old_mode eq 'WRITE' or $new_mode eq 'READ') {
	return $self->{state};
    }
    state_file_close($self);
    return state_file_open($self, $new_mode, $if_blocked);
}

#
# Bundle Interface
#

sub update		{ unsupported_interface("bundle", @_) }
sub abandon_update	{ unsupported_interface("bundle", @_) }
sub continue_update	{ unsupported_interface("bundle", @_) }
sub update_status	{ unsupported_interface("bundle", @_) }

# 
# Server Interface
#

# Should inplementing C<cmd_configure> be optional?
sub cmd_configure	{ unsupported_interface("server", @_) }
sub cmd_start		{ unsupported_interface("server", @_) }
sub stop		{ unsupported_interface("server", @_) }
sub status		{ unsupported_interface("server", @_) }
sub pid			{ unsupported_interface("server", @_) }
sub rm_pid		{ unsupported_interface("server", @_) }

1;
__END__

# Local Variables:
# mode: Perl
# End:
