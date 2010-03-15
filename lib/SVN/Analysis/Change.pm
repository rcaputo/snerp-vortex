package SVN::Analysis::Change;

use Moose;
use Carp qw(croak);

has revision => ( is => 'rw', isa => 'Int', required => 1 );

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

sub is_add    { 0 }
sub is_copy   { 0 }
sub is_delete { 0 }
sub is_touch  { 0 }
sub exists    { 0 }

sub as_xml_element {
	my ($self, $document) = @_;

	my $change = $document->createElement("change");
	$change->appendTextNode(ref $self);
	$change->setAttribute(revision      => $self->revision());
	$change->setAttribute(entity_type   => $self->entity_type());
	$change->setAttribute(entity_name   => $self->entity_name());
	$change->setAttribute(relocate_path => $self->relocate_path());

	return $change;
}

sub new_from_xml_element {
	my ($self, $element) = @_;
	my $change_class = $element->textContent();
	return $change_class->new(
		map { $_->nodeName(), $_->value() }
		$element->attributes()
	);
}

1;
