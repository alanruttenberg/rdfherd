#!perl -T
# $Id: pod.t 1701 2008-03-25 22:25:13Z bawden $

use Test::More;
eval "use Test::Pod 1.14";
plan skip_all => "Test::Pod 1.14 required for testing POD" if $@;
all_pod_files_ok();
