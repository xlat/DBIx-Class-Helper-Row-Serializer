package DBIx::Class::Helper::Row::Serializer;

#ABSTRACT: Convenient serializing with DBIx::Class.
use Modern::Perl;
use parent 'DBIx::Class::Row';

# 'is_serializable' may conflict with DBIx::Class::Helper::Row::ToJSON
my $IS_SERIALISABLE  = 'is_serializable';

__PACKAGE__->mk_group_accessors(inherited => '__serializable_columns');
__PACKAGE__->mk_group_accessors(inherited => '__serializable_relationships');

sub __is_column_serializable {
    my ( $self, $column ) = @_;
    my $info = $self->column_info($column);
    if (!defined $info->{$IS_SERIALISABLE}) {
        #ignore autoincrement columns
    if (exists $info->{is_auto_increment} &&
            $info->{$info->{is_auto_increment}}
        ) {
            $info->{$IS_SERIALISABLE} = 0;
        } else {
            $info->{$IS_SERIALISABLE} = 1;
        }
    }
    return $info->{$IS_SERIALISABLE};
}
 
sub _serializable_columns {
    my $self = shift;
    if (!$self->__serializable_columns) {
        my $rsrc = $self->result_source;
        my %fk_columns = 
            map { %{  $_->{attrs}{fk_columns}  } }
            grep{ exists $_->{attrs}{fk_columns} }
            map { $rsrc->relationship_info($_)   }
            $rsrc->relationships;
		$DB::single=1;
        $self->__serializable_columns([
            grep $self->__is_column_serializable($_),
            #ignore fkeys by defaults
            grep { !exists $fk_columns{$_} }
                $self->result_source->columns
        ]);
   }
   return $self->__serializable_columns;
}

sub __is_relationship_serializable {
    my ( $self, $rel_name ) = @_;
    
    my $rsrc = $self->result_source;
    my $rel_info = $rsrc->relationship_info($rel_name);
    
    if(!exists $rel_info->{attrs}{$IS_SERIALISABLE}){
        $rel_info->{attrs}{$IS_SERIALISABLE} = 
            $rel_info->{attrs}{cascade_copy} // 0;
    }

    return $rel_info->{attrs}{$IS_SERIALISABLE};
}

sub _serializable_relationships {
    my $self = shift;
    if (!$self->__serializable_relationships) {
        $self->__serializable_relationships([
            grep $self->__is_relationship_serializable($_),
                $self->result_source->relationships
        ]);
   }
   return $self->__serializable_relationships;
}

=head2 serialize

    $self->serialize
    
returns a serialisation of your object, typicaly a hashref.

=cut
sub serialize{
    my ($self, %args) = @_;
	return unless $self->isa('DBIx::Class::Helper::Row::Serializer');
    my $columns = $self->_serializable_columns;
    my $columns_info = $self->columns_info(@$columns);
	my $col_data = {
        map +($_ => $self->$_),
        map +($columns_info->{$_}{accessor} || $_),
        keys %$columns_info
    };
	 my $rel_names_copied = {};
     my $rsrc = $self->result_source;
     my $relationships = $self->_serializable_relationships;
	RELATIONSHIP:
	foreach my $rel_name (@$relationships) {
		my $rel_info = $rsrc->relationship_info($rel_name);
		$DB::single = 1 unless $rel_info->{class};
		my $serializer = exists $rel_info->{attrs}{serialize}
						 ? $rel_info->{attrs}{serialize}
						 : ( $rel_info->{class}->can('serialize')
							// \&serialize )
                         ;
		my $copied = $rel_names_copied->{ $rel_info->{source} } ||= {};
		my @relateds =
            map { $serializer->($_, %args) }
            grep{ $copied->{$_->ID}++ == 0 }
    		$self->search_related($rel_name)->all;
		$col_data->{$rel_name} = \@relateds if @relateds;
	}
	$col_data->{__CLASS__} = ref($self) if $args{debug} or $args{class};
	return $col_data;
}

1;
