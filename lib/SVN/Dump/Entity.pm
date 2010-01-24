package SVN::Dump::Entity;

# Represent a SVN entity: branch or tag.

use Moose;
use Carp qw(cluck carp);

has first_revision_id => ( is => 'rw', isa => 'Int', required => 1 );
has last_revision_id  => ( is => 'rw', isa => 'Int', required => 1 );
has type              => ( is => 'rw', isa => 'Str', required => 1 );
has name              => ( is => 'rw', isa => 'Str', required => 1 );
has exists            => ( is => 'rw', isa => 'Bool', required => 1 );
has path              => ( is => 'ro', isa => 'Str', required => 1 );

# Tags that are changed after the fact are really branches.
# Likewise, branches that haven't been changed may as well be tags.

sub fix_type {
	my $self = shift;

	my $type = $self->type();

	if ($type eq "tag") {
		if ($self->first_revision_id() != $self->last_revision_id()) {
			warn "converting ", $self->type(), " ", $self->name, " to branch";
			$self->type("branch");
		}
		return;
	}

	if ($type eq "branch") {
		if ($self->first_revision_id() == $self->last_revision_id()) {
			warn "converting ", $self->type(), " ", $self->name, " to tag";
			$self->type("tag");
		}
		return;
	}

	return if $type eq "meta";

	confess "entity has unexpected type: " . $self->type();
}

sub debug {
	my ($self, $template) = @_;
	sprintf $template, $self->type() . " " . $self->name();
}

1;
