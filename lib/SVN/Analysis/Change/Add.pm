package SVN::Analysis::Change::Add;

use Moose;
extends 'SVN::Analysis::Change::Exists';

sub is_add { 1 }

1;
