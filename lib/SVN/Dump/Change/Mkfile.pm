package SVN::Dump::Change::Mkfile;

use Moose;
extends 'SVN::Dump::Change::Edit';

has '+callback' => ( default => 'on_file_creation' );

1;
