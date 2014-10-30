# Virtuoso Server Instance Configuration File
#
# This file should be edited and installed with the name "Config.pl" in an
# empty directory that will become the working directory for a Virtuoso
# server.
#
# The file /etc/rdfherd-config.pl contains system-wide default values for
# all of the settings in this file.
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
# $Id: virtuoso-server-Config.pl 2288 2009-03-05 23:40:11Z bawden $

{

##### SET THESE FIRST EIGHT TO APPROPRIATE VALUES FOR THIS SERVER:

    # Set these to the TCP port numbers you want to use.  These must not
    # conflict with other servers on your machine, so if you're not the
    # systems administrator for this machine, you might want to talk to him
    # to see what ports he thinks you should use.  Note that http_port is
    # where the Virtuoso web server will appear, so this number will need
    # to be communicated to other people.  The sql_port is needed if you
    # use the "isql" program to talk to the server.
    #
    # Remember that Virtuoso uses ports 1111, 1121, 1131, 1112, 5111, 6111,
    # 7111, 8111, 8112, and maybe others, at build time, so those are all
    # bad choices...
    #
    # You can't leave these set to zero like this.
    #
    http_port => 0,
    sql_port => 0,

    # List here all the legal notices that you have read.
    #
    # If a bundle comes with a notice that you must read before being able
    # to use the data, RDFHerd will not allow you to load that bundle into
    # the server until the name of the file containing the notice appears
    # in this list.  By listing a file here, you agree that you have read
    # it.
    #
    # These should all be pathnames relative to your bundle directory
    # (where all of your data feeds live).
    #
    notices_read => [
	# Currently no bundles require this.
	],

    # The Unix user who should run this virtuoso server instance and owns
    # all of the files it uses.  The rdfherd command will insist that you
    # be this user before it will let you do any operation that might
    # require extra permission.  We recommend that you create a "virtuoso"
    # user and group, and use sudo to run the rdfherd command as this user.
    #
    require_user => "virtuoso",

    # Virtuoso docs suggest setting number_of_buffers to about 2/3 of
    # available RAM.  Virtuoso docs suggest setting max_dirty_buffers to
    # about 3/4 of number_of_buffers.
    #
    # These are measured in 8K buffers, but we are told that actually each
    # buffer costs 9K in actual memory used.
    #
    # That would suggest settings such as:
    #	For 4G:
    #	    number_of_buffers => 320_000,
    # 	    max_dirty_buffers => 240_000,
    #	For 8G:
    #	    number_of_buffers => 640_000,
    #	    max_dirty_buffers => 480_000,
    #	For 16G:
    #	    number_of_buffers => 1_280_000,
    #	    max_dirty_buffers =>   960_000,
    #
    # On Ashby (our original server), which had 8G, we actually ran with:
    #	    number_of_buffers => 450_000,
    #	    max_dirty_buffers => 300_000,
    #
    # The values below would be about right for a machine with 1/2 G of
    # memory.  That's pretty small for modern hardware.  If you care about
    # performance, figure out how much physical memory you have and replace
    # these with larger values.
    #
    number_of_buffers => 40_000,
    max_dirty_buffers => 30_000,

    # Depending on how many queries your server is processing at a time,
    # you might want to increase these above their default value of 10.
    #
    #server_threads => 10,
    #http_threads => 10,

##### If you're building a Neurocommons mirror, you probably won't need to
##### change anything below this point.  

    # Allocate a 50G, striped database.  Note that file_extend will be
    # applied to I<every> stripe, so the actual increment of growth is 512M
    # times the number of disks you have.  (E.g., if you have 2 disks, the
    # setting below grows your database in 1G increments.)
    #
    # Note also that versions of Virtuoso before 5.0.7 do not know how to
    # extend a striped database -- instead you have to manually increase
    # the segment count and reconfigure.  (You can INCREASE the segment
    # count after creating a database.  You may not DECREASE it.
    # Decreasing it will destroy your database!)
    #
    striping => 1,
    segment_size => "5G",
    segment_count => 10,
    file_extend => 64 * 1024, # in 8K blocks for 512M increments

    # Presumably max_checkpoint_remap should be proportional to the size of
    # your database, assuming I'm reading the Virtuoso docs correctly.
    # (This claims to be measured in "pages", but apparently "page" is
    # synonymous with "buffer" here.)  We've been using the value 250,000
    # for a 40G database and it seems to work fine, but in the "Virtuoso
    # RDF Performance Tuning" section they write: "... if running with a
    # large database, setting MaxCheckpointRemap to 20% of the database
    # size is recommended. This is in pages, 8K per page."  That would
    # suggest setting this to something more like 800,000...
    #
    max_checkpoint_remap => 250_000,
    #max_checkpoint_remap => 800_000,

    # This limits the size of transaction that Virtuoso will support.  It
    # is measured in bytes (not multiples of 8K like many related
    # parameters).  By default this is set to 50M.  Early in our experience
    # with Virtuoso it was necessary to bump this up in order to load
    # large RDF files.  We load RDF differently now, so we probably
    # don't need this, but it isn't hurting us and we might be accidentally
    # depending on it somewhere else.
    #
    transaction_after_image_limit => 300_000_000,

    # More FDs mean more I/O can overlap.
    #
    fds_per_file => 4,

    # If you're mostly processing SPARQL queries, this is what you want.
    #
    default_isolation => 2,
	
    # The Virtuoso docs also mention there being an "UnremapQuota"
    # parameter that presumably is also relevant here, but it is unclear
    # how to be rational about setting it, or even what it's default value
    # might be...

    # AlanB recommends you keep this commented out until you need it, but
    # AlanR thinks you should always run with this set.  Note that you can
    # call trace_on() to enable tracing in a running server...
    #
    #trace_on => "compile, exec, errors",

    # This keeps Virtuoso's messages out of /var/log/messages.  If you
    # uncomment the trace_on setting above, you will definitely want this
    # set to 0.  If you want Virtuoso messages in your syslog files, set
    # this to 1.
    #
    syslog => 0,

    # execution_timeout works in older version of Virtuoso.
    # max_query_execution_time works in newer versions.  (Actually, neither
    # one works in Virtuoso 5.0.8, but OpenLink fixed that in later
    # releases.)
    #
    # This is time measured in seconds.  That might not be enough for your
    # most complex queries, but it might be too large if you are running a
    # busy public server.  Adjust as needed.
    #
    execution_timeout => 30 * 60 * 60,
    max_query_execution_time => 30 * 60 * 60,

    # The RDFHerd tools use this to figure out what this directory is for.
    # This is not something you can change.  Leave it alone.
    #
    class => "Virtuoso Server",

}
