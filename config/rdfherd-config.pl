# System-wide configuration file for RDFHerd.
#
# This file should be edited and installed as: /etc/rdfherd-config.pl
#
# This file is parsed by Perl, so all of your questions about the details
# of its syntax can be found in the Perl documentation.  But really, the
# syntax should be pretty obvious from the examples herein.
#
# (The only non-obvious hazard is that Perl is surprisingly persnickety
# about putting commas between all list elements.  If you edit this file,
# and then get some error message you find incomprehensible, the answer is
# almost certainly that you left out a comma somewhere.)
#
# $Id: rdfherd-config.pl 3470 2010-06-16 22:35:23Z bawden $

{

    # The virtuoso_default_defaults section defines the default values seen
    # by all Virtuoso server instances.  Values here can be overridden in
    # each server instance's Config.pl file.
    #
    virtuoso_default_defaults => {

##### SET THESE FIRST FIVE TO APPROPRIATE VALUES FOR YOUR INSTALLATION:

	# Set this to the directory where all your RDF bundles live.
	#
	bundle_dir => "/bundle_dir",

	# Each element of stripe_dirs is the name of a directory on a
	# different disk that you have allocated for Virtuoso striping.
	# For each server instance named "foo", we will create a
	# subdirectory named "foo" in I<each> of these directories.
	#
	stripe_dirs => ["/stripe0", "/stripe1", "/stripe2", "/stripe3"],

	# How many CPU cores do you have?
	#
	cpu_cores => 1,

	# If Virtuoso was configured with prefix=/some/prefix, set
	# this to "/some/prefix".
	#
	install_dir => "/usr/local",

	# Set this to 1 if you have applied the file_to_string.patch
	# <http://ftp.neurocommons.org/export/file_to_string.patch> to your
	# Virtuoso.  Every version before 5.0.12 needed this patch.
	#
	# RDFHerd versions 1.01 through 1.18 -require- either this patch,
	# or Virtuoso 5.0.12 or later.
	#
	# Note that prior to RDFHerd version 1.18, you had to set this to
	# 1, even if you were running a recent Virtuoso that didn't require
	# the patch.  If you're confused now, don't be: If you're reading
	# this, then you've already got at least RDFHerd 1.18, so just set
	# this to reflect whether or not you applied the patch.
	#
	file_to_string_patch => 0,

##### You probably don't need to change anything below this point.	

	# The user (in Virtuoso's own user account database) who has access
	# to load data into your database.  You'll need to know this guy's
	# password.  By default, we use Virtuoso's superuser, "dba".  His
	# password is "dba" by default, but you changed that to something
	# else, right?
	#
	virtuoso_user => "dba",

	# Uncomment any of these if you need them.  Note that you might
	# have to recompile Virtuoso to get some of these.
	#
	# Actually, you're probably better off leaving this defined to be
	# the empty list, and defining "plugins" appropriately in the server
	# instance Config.pl file.
	#
	plugins => [
	    # "plain, wikiv",
	    # "plain, mediawiki",
	    # "plain, creolewiki",
	    # "plain, im",
	    # "plain, wbxml2",
	    # "Hosting, hosting_php.so",
	    # "Hosting, hosting_perl.so",
	    # "Hosting, hosting_python.so",
	    # "Hosting, hosting_ruby.so",
	    # "msdtc, msdtc_sample",
	],

	# By default, we allocate a 5G, striped, single segment database.
	# Note that file_extend will be applied to I<every> stripe, so the
	# actual increment of growth is 512M times the number of disks you
	# have.  Note also that versions of Virtuoso before 5.0.7 do not
	# know how to extend a striped database -- instead you have to
	# manually increase the segment count and reconfigure.
	#
	striping => 1,
	segment_size => "5G",
	segment_count => 1,
	file_extend => 64 * 1024, # in 8K blocks for 512M increments

    },
    
}
