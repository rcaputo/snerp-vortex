package SVN::Analysis::Change;

use Moose;
use Carp qw(croak);

has revision => ( is => 'rw', isa => 'Int', required => 1 );

has entity_type => (
	is      => 'rw',
	isa     => 'Str',
	default => "",
);

has entity_name => (
	is      => 'rw',
	isa     => 'Str',
	default => "",
);

has path_lop => (
	is      => 'rw',
	isa     => 'Str',
	lazy    => 1,
	default => sub { croak "uninitialized path_lop" },
);

has path_prepend => (
	is      => 'rw',
	isa     => 'Str',
	lazy    => 1,
	default => sub { croak "uninitialized path_prepend" },
);

has path => (
	is      => 'rw',
	isa     => 'Str',
	lazy    => 1,
	default => sub { croak "uninitialized path" },
);

sub is_entity {
	my $self = shift;
	return $self->path() eq $self->path_lop();
}

sub is_branch {
	my $self = shift;
	return $self->entity_type() eq "branch";
}

sub is_add    { 0 }
sub is_copy   { 0 }
sub is_delete { 0 }
sub is_touch  { 0 }
sub exists    { 0 }

sub relocated_path {
	my $self = shift;
	return $self->fix_path($self->path());
}

sub fix_path {
	my ($self, $path) = @_;

	my $path_lop = $self->path_lop();
	my $path_prepend = $self->path_prepend();

	$path =~ s!^\Q$path_lop\E(?:/|$)!$path_prepend!;

	return $path;
}

sub as_xml_element {
	my ($self, $document) = @_;

	my $change = $document->createElement("change");
	$change->appendTextNode(ref $self);
	$change->setAttribute(revision      => $self->revision());
	$change->setAttribute(entity_type   => $self->entity_type());
	$change->setAttribute(entity_name   => $self->entity_name());
	$change->setAttribute(path          => $self->path());
	$change->setAttribute(path_lop      => $self->path_lop());
	$change->setAttribute(path_prepend  => $self->path_prepend());

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
