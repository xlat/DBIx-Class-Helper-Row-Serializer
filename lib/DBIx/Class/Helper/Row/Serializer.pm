package DBIx::Class::Helper::Row::Serializer;

#ABSTRACT: Convenient serializing with DBIx::Class.
use Modern::Perl;
use parent 'DBIx::Class::Row';

# 'is_serializable' may conflict with DBIx::Class::Helper::Row::ToJSON
my $IS_SERIALISABLE  = 'is_serializable';

__PACKAGE__->mk_group_accessors(inherited => '_hrs_serializable_columns');
__PACKAGE__->mk_group_accessors(inherited => '_hrs_serializable_relationships');

sub hrs_is_column_serializable {
    my ( $self, $column ) = @_;
    my $info = $self->column_info($column);
    if (!defined $info->{$IS_SERIALISABLE}) {
        #ignore autoincrement columns
    if (exists $info->{is_auto_increment} &&
            $info->{is_auto_increment}
        ) {
            $info->{$IS_SERIALISABLE} = 0;
        } else {
            $info->{$IS_SERIALISABLE} = 1;
        }
    }
    return $info->{$IS_SERIALISABLE};
}
 
sub hrs_serializable_columns {
    my $self = shift;
    if (!$self->_hrs_serializable_columns) {
        my $rsrc = $self->result_source;
        my %fk_columns = 
            map { %{  $_->{attrs}{fk_columns}  } }
            grep{ exists $_->{attrs}{fk_columns} }
            map { $rsrc->relationship_info($_)   }
            $rsrc->relationships;
        $self->_hrs_serializable_columns([
            grep $self->hrs_is_column_serializable($_),
            #ignore fkeys by defaults
            grep { !exists $fk_columns{$_} }
                $self->result_source->columns
        ]);
   }
   return $self->_hrs_serializable_columns;
}

sub hrs_is_relationship_serializable {
    my ( $self, $rel_name ) = @_;
    
    my $rsrc = $self->result_source;
    my $rel_info = $rsrc->relationship_info($rel_name);
    
    if(!exists $rel_info->{attrs}{$IS_SERIALISABLE}){
        $rel_info->{attrs}{$IS_SERIALISABLE} = 
            $rel_info->{attrs}{cascade_copy} // 0;
    }

    return $rel_info->{attrs}{$IS_SERIALISABLE};
}

sub hrs_serializable_relationships {
    my $self = shift;
    if (!$self->_hrs_serializable_relationships) {
        $self->_hrs_serializable_relationships([
            grep $self->hrs_is_relationship_serializable($_),
                $self->result_source->relationships
        ]);
   }
   return $self->_hrs_serializable_relationships;
}

sub serialize{
    my ($self, %args) = @_;
	return unless $self->isa('DBIx::Class::Helper::Row::Serializer');
	
    my $columns = $self->hrs_serializable_columns;
    my $columns_info = $self->columns_info($columns);
	my $col_data = {
        map +($_ => $self->$_),
        map +($columns_info->{$_}{accessor} || $_),
        keys %$columns_info
    };
	 my $rel_names_copied = {};
     my $rsrc = $self->result_source;
     my $relationships = $self->hrs_serializable_relationships;
	RELATIONSHIP:
	foreach my $rel_name (@$relationships) {
		my $rel_info = $rsrc->relationship_info($rel_name);
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

sub unserialize{
    my ($self, $serialized, %args) = @_;
    unless(ref($serialized) eq 'HASH'){
        $DB::single=1;
        return;
    }
    #~ if(!ref($self) and $self eq __PACKAGE__){
        #~ return $self->new->unserialize($serialized, %args);
    #~ }

    #- unserialize first all relationships (resursively) and push some defered in a queue with everything needed to attach it with it's container
    my $rsrc = $self->result_source;
    my @defereds;
    my $relationships = $self->hrs_serializable_relationships;
    RELATION:
    for my $rel_name ( @$relationships ){
        my $related = delete $serialized->{$rel_name}
            or next RELATION;
        my $related_class = $rsrc->relationship_info($rel_name)->{class};
        push @defereds, [$related_class => $rel_name => $related];
    }
    #   and to do something like: $self->new_related( $rel_name => $related_data )
    #- unserialize $self attributs like $self = $self->new( $data )
    $DB::single=1 unless ref($serialized) eq 'HASH';
    $self->set_columns( $serialized );
    # - process defered queue for attaching relationships to $self
    DEFERED:
    for my $related ( @defereds ){
        my ($class, $name, $data) = @$related;
        #TODO: assert for $class->can('unserialize');
        #               but it should be the case as it's supposed to be serialized!
        my $entity = $class->new->unserialize( $data , %args )
            or next DEFERED;
        #unsure!
        $self->new_related( $name => $entity );
    }
    # - return toplevel entity (not saved!)
    return $self;
}

#injection hacks
sub unserialize_rs{
    my ($rs,  @serialized) = @_;
    #~ my $result_class = $rs->result_source->result_class;
    #magically works even if result-class does not have imported Helper::Row::Serializer component.
    #~ my @deserialized = map{ DBIx::Class::Helper::Row::Serializer::unserialize($result_class->new(), $_) } @serialized;
    my @deserialized = map{ DBIx::Class::Helper::Row::Serializer::unserialize($rs->new({}), $_) } @serialized;
    return @deserialized if @serialized > 1;
    return $deserialized[0];
}

package DBIx::Class::Helper::ResultSet::Seriliazer;
sub unserialize{ &DBIx::Class::Helper::Row::Serializer::unserialize_rs  }
require DBIx::Class::ResultSet;
DBIx::Class::ResultSet->load_components('+DBIx::Class::Helper::ResultSet::Seriliazer');
1;
