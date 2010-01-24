package SVN::Dump::Change::Cpfile;

use Moose;
extends 'SVN::Dump::Change::Copy';

has '+callback' => ( default => 'on_file_copy' );

1;
