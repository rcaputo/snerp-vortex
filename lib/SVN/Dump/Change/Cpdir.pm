package SVN::Dump::Change::Cpdir;

use Moose;
extends 'SVN::Dump::Change::Copy';

has '+operation' => ( default => 'directory_copy' );

1;
