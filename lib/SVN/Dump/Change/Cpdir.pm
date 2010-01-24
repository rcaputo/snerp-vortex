package SVN::Dump::Change::Cpdir;

use Moose;
extends 'SVN::Dump::Change::Copy';

has '+callback' => ( default => 'on_directory_copy' );

1;
