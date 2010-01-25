package SVN::Dump::Change::Mkfile;

use Moose;
extends 'SVN::Dump::Change::Edit';

has '+operation' => ( default => 'file_creation' );

1;
