#!/usr/bin/env perl

use warnings;
use strict;
use lib qw(./lib);

use SVN::Dump::Replayer::Git;

my $authors_file    = "/home/troc/projects/authors.txt";
my $svn_replay_base = "/Volumes/snerp-vortex-workspace/poe-svn-replay";
my $svn_dump_file   = "/home/troc/projects/git/poe-svn.dump";
my $svn_cp_src_dir  = "/Volumes/snerp-vortex-workspace/poe-svn-copies";
my $git_replay_base = "/Volumes/snerp-vortex-workspace/poe-git-replay";

my $replayer = SVN::Dump::Replayer::Git->new(
	svn_dump_filename => $svn_dump_file,
	svn_replay_base   => $svn_replay_base,
	copy_source_depot => $svn_cp_src_dir,
	git_replay_base   => $git_replay_base,
	authors_file      => $authors_file,
);

$replayer->do_rmdir($svn_replay_base) if -e $svn_replay_base;
$replayer->do_mkdir($svn_replay_base);

$replayer->do_rmdir($svn_cp_src_dir) if -e $svn_cp_src_dir;
$replayer->do_mkdir($svn_cp_src_dir);

$replayer->walk();
