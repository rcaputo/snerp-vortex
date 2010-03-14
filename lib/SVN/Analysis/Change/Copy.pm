package SVN::Analysis::Change::Copy;

use Moose;
extends 'SVN::Analysis::Change';

has src_path      => ( is => 'ro', isa => 'Str', default  => "" );
has src_revision  => ( is => 'ro', isa => 'Str', default  => "" );

sub is_add    { 0 }
sub is_copy   { 1 }
sub is_delete { 0 }
sub is_touch  { 0 }
sub exists    { 1 }

around as_xml_element => sub {
	my ($orig, $self, $document) = @_;
	my $element = $self->$orig($document);
	$element->setAttribute(src_path     => $self->src_path());
	$element->setAttribute(src_revision => $self->src_revision());
	return $element;
};

1;
