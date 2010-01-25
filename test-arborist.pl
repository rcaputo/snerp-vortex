#!/usr/bin/env perl

use warnings;
use strict;
use lib qw(./lib);

{
	package SVN::Dump::Narrator;
	use Moose;
	extends 'SVN::Dump::Replayer';

#	sub on_branch_creation {
#		my ($self, $branch_name) = @_;
#		print "  git checkout -b $branch_name\n";
#	}
#
#	sub on_branch_destruction {
#		my ($self, $branch_name) = @_;
#		print(
#			"  git checkout master\n",
#			"  git branch -d $branch_name\n",
#		);
#	}
#
#	sub on_branch_rename {
#		my ($self, $old_branch_name, $new_branch_name) = @_;
#		print(
#			"  git checkout master\n",
#			"  git branch -m $old_branch_name $new_branch_name\n",
#		);
#	}
#
#	sub on_tag_creation {
#		my ($self, $branch_name, $tag_name) = @_;
#		print "  git tag -a -m 'TODO: Tag annotation.' $tag_name $branch_name\n";
#	}
#
#	sub on_tag_destruction {
#		my ($self, $tag_name) = @_;
#		print "  git tag -d $tag_name\n";
#	}
#
#	sub on_tag_rename {
#		my ($self, $old_tag_name, $new_tag_name) = @_;
#		print(
#			"  git tag -a -m 'TODO: Tag annotation.' $new_tag_name $old_tag_name\n",
#			"  git tag -d $old_tag_name\n",
#		);
#	}
#
#	sub on_file_creation {
#		my ($self, $branch_name, $file_path, $file_content) = @_;
#		print(
#			"  git checkout $branch_name\n",
#			"  vim $file_path\n",
#		);
#	}
#
#	sub on_file_change {
#		my ($self, $branch_name, $file_path, $file_content) = @_;
#		print(
#			"  git checkout $branch_name\n",
#			"  vim $file_path\n",
#		);
#	}
#
#	sub on_file_deletion {
#		my ($self, $branch_name, $file_path) = @_;
#		print(
#			"  git checkout $branch_name\n",
#			"  rm $file_path\n",
#		);
#	}
#
#	sub on_file_rename {
#		my ($self, $branch_name, $old_file_path, $new_file_path) = @_;
#		print(
#			"  git checkout $branch_name\n",
#			"  git mv $old_file_path $new_file_path\n",
#		);
#	}
#
#	sub on_directory_creation {
#		my ($self, $branch_name, $directory_path) = @_;
#		print(
#			"  git checkout $branch_name\n",
#			"  mkdir $directory_path\n",
#		);
#	}
#
#	sub on_directory_deletion {
#		my ($self, $branch_name, $directory_path) = @_;
#		print(
#			"  git checkout $branch_name\n",
#			"  rmdir $directory_path\n",
#		);
#	}
#
#	sub on_directory_rename {
#		my ($self, $branch_name, $old_directory_path, $new_directory_path) = @_;
#		print(
#			"  git checkout $branch_name\n",
#			"  mv $old_directory_path $new_directory_path\n",
#		);
#	}

	no Moose;
}

###

my $authors_file    = "/home/troc/projects/authors.txt";
my $svn_replay_base = "/Volumes/snerp-vortex-workspace/poe-replay";
my $svn_dump_file   = "/home/troc/projects/git/poe-svn.dump";
my $svn_cp_src_dir  = "/Volumes/snerp-vortex-workspace/poe-copy-sources";

system("rm -rf $svn_replay_base") and die $!;
system("mkdir $svn_replay_base") and die $!;

system("rm -rf $svn_cp_src_dir") and die $!;
system("mkdir $svn_cp_src_dir") and die $!;

###

my $replayer = SVN::Dump::Narrator->new(
	svn_dump_filename => $svn_dump_file,
	svn_replay_base   => $svn_replay_base,
	copy_source_depot => $svn_cp_src_dir,
);

$replayer->walk();

###

# TODO - Clean up after ourselves?
#system("rmdir $svn_replay_base") and die $!;
