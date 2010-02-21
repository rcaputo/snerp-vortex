package SVN::Dump::Copy;

use Moose;

has src_revision  => ( is => 'ro', isa => 'Int', required => 1 );
has src_path      => ( is => 'ro', isa => 'Str', required => 1 );
has dst_revision  => ( is => 'ro', isa => 'Int', required => 1 );
has dst_path      => ( is => 'ro', isa => 'Str', required => 1 );

sub debug {
	my ($self, $template) = @_;
	return sprintf(
		$template,
		sprintf(
			"copy from %s \@%s to %s \@%s",
			$self->src_path(), $self->src_revision(),
			$self->dst_path(), $self->dst_revision(),
		)
	)
}

1;
