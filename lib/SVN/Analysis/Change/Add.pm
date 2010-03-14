package SVN::Analysis::Change::Add;

use Moose;
extends 'SVN::Analysis::Change';

sub is_add    { 1 }
sub is_copy   { 0 }
sub is_delete { 0 }
sub is_touch  { 0 }
sub exists    { 1 }

1;
