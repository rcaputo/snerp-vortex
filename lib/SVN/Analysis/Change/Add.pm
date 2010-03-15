package SVN::Analysis::Change::Add;

use Moose;
use Carp qw(croak);

extends 'SVN::Analysis::Change::Exists';

has entity_type => (
	is      => 'rw',
	isa     => 'Str',
	lazy    => 1,
	default => sub { croak "uninitialized entity_type" },
);

has entity_name => (
	is      => 'rw',
	isa     => 'Str',
	lazy    => 1,
	default => sub { croak "uninitialized entity_name" },
);

has relocate_path => (
	is      => 'rw',
	isa     => 'Str',
	lazy    => 1,
	default => sub { croak "uninitialized relocate_path" },
);

sub is_add { 1 }

around as_xml_element => sub {
	my ($orig, $self, $document) = @_;
	my $element = $self->$orig($document);
	$element->setAttribute(entity_type   => $self->entity_type());
	$element->setAttribute(entity_name   => $self->entity_name());
	$element->setAttribute(relocate_path => $self->relocate_path());
	return $element;
};

1;
