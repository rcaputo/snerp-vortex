package SVN::Analysis::Change::Touch;

use Moose;
extends 'SVN::Analysis::Change';

sub is_add    { 0 }
sub is_copy   { 0 }
sub is_delete { 0 }
sub is_touch  { 1 }
sub exists    { 1 }

1;
