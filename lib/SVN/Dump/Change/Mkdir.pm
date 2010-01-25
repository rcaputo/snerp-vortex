package SVN::Dump::Change::Mkdir;

use Moose;
extends 'SVN::Dump::Change';

has '+operation' => ( default => 'directory_creation' );

1;
