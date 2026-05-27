package Demo::Widget;
use strict;
use warnings;
use feature qw(say state);

sub new {
  my ($class, %args) = @_;
  return bless { name => $args{name} // 'demo' }, $class;
}

sub from_env {
  my ($class) = @_;
  my %args = map { split /=/, $_, 2 } grep { /=/ } @ARGV;
  return $class->new(name => $args{name} || $ENV{WIDGET_NAME});
}

sub render {
  my ($self, @items) = @_;
  state $count = 0;
  $count++;
  my @labels = map { "$self->{name}:$_->{label}" } grep { $_->{enabled} } @items;
  return join ', ', sort @labels;
}

=pod

=head1 NAME

Demo::Widget - render enabled labels

=cut

my $widget = Demo::Widget->from_env;
say $widget->render({ enabled => 1, label => "alpha" });

1;
