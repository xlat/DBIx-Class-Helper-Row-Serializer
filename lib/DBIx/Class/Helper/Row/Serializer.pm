package DBIx::Class::Helper::Row::Serializer;
use Modern::Perl;
#ABSTRACT: Convenient serializing with DBIx-Class
# VERSION
use parent 'DBIx::Class::Row';
use constant DEBUG => 0;

# 'is_serializable' may conflict with DBIx::Class::Helper::Row::ToJSON
my $HRS = 'DBIx::Class::Row';
$HRS->mk_group_accessors(inherited => '_hrs_is_serializable');
$HRS->_hrs_is_serializable('is_serializable');

=head2 IS_SERIALIZABLE

Should not be manipulated, reserved for internal usages.
If attribut 'is_serializable' conflicts with DBIC:R:H:ToJSON,
just make a call in your Result base class to
DBIx::Class::Row->_hrs_is_serializable('other_is_serializable').
It will change the attribut name this package will look at in place
of 'is_serializable'.

=cut
sub IS_SERIALIZABLE{ $HRS->_hrs_is_serializable }

__PACKAGE__->mk_group_accessors(inherited => '_hrs_serializable_columns');
__PACKAGE__->mk_group_accessors(inherited => '_hrs_serializable_relationships');

=head2 hrs_is_column_serializable

Should not be manipulated, reserved for internal usages.

=cut
sub hrs_is_column_serializable {
    my ( $self, $column ) = @_;
    my $info = $self->column_info($column);
    if (!defined $info->{IS_SERIALIZABLE()}) {
        #ignore autoincrement columns
        if (exists $info->{is_auto_increment} &&
            $info->{is_auto_increment}
        ) {
            $info->{IS_SERIALIZABLE()} = 0;
        } else {
            $info->{IS_SERIALIZABLE()} = 1;
        }
    }
    return $info->{IS_SERIALIZABLE()};
}

=head2 hrs_serializable_columns

Should not be manipulated, reserved for internal usages.

=cut 
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

=head2 hrs_is_relationship_serializable

Should not be manipulated, reserved for internal usages.

=cut 
sub hrs_is_relationship_serializable {
    my ( $self, $rel_name ) = @_;
    
    my $rsrc = $self->result_source;
    my $rel_info = $rsrc->relationship_info($rel_name);
    
    if(!exists $rel_info->{attrs}{IS_SERIALIZABLE()}){
        $rel_info->{attrs}{IS_SERIALIZABLE()} = 
            $rel_info->{attrs}{cascade_copy} // 0;
    }

    return $rel_info->{attrs}{IS_SERIALIZABLE()};
}

=head2 hrs_serializable_relationships

Should not be manipulated, reserved for internal usages.

=cut 
sub hrs_serializable_relationships {
    my $self = shift;
    if (!$self->_hrs_serializable_relationships) {
        my $rs = $self->result_source;
        $self->_hrs_serializable_relationships([ 
            sort {
                #customize relation priority see "04_unserialize_relations.t".
                my $a_ri = $rs->relationship_info($a);
                my $b_ri = $rs->relationship_info($b);
                my $a_priority = $a_ri->{attrs}{unserialization_priority}//0;
                my $b_priority = $b_ri->{attrs}{unserialization_priority}//0;
                $b_priority <=> $a_priority
            }
            grep $self->hrs_is_relationship_serializable($_), 
                $rs->relationships
        ]);
   }
   return $self->_hrs_serializable_relationships;
}


=head2 serialize

Serialize a ResultClass and embedded ones

    my $serial = $self->serialize(\%args);
    

=cut
sub serialize{
    my ($self, $args, $root, $container) = @_;
	return unless $self->isa('DBIx::Class::Helper::Row::Serializer');
	$root //= $self;
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
		my $serializer = exists $rel_info->{attrs}{serializer}
						 ? $rel_info->{attrs}{serializer}
						 : ( $rel_info->{class}->can('serialize')
							// \&serialize )
                         ;
		my $copied = $rel_names_copied->{ $rel_info->{source} } ||= {};
		my @relateds =
            map { $serializer->($_, $args, $root, $self) }
            grep{ $copied->{$_->ID}++ == 0 }
    		$self->search_related($rel_name)->all;
        if(@relateds){
            if(($rel_info->{attrs}{accessor} || '') eq 'single'){
                $col_data->{$rel_name} = shift @relateds;
            }
            else{
                $col_data->{$rel_name} = \@relateds;
            }
        }
	}
	$col_data->{__CLASS__} = ref($self) if $args->{debug} or $args->{class};
	return $col_data;
}

=head2 unserialize

Unzerialize a ResultClass but did not store.

    my $result = $self->unserialize($serial);
    $result->insert;
    
=cut 
sub unserialize{
    my ($self, $serialized, $args, $root, $container) = @_;
    unless(ref($serialized) eq 'HASH'){
        warn "unserialize must take a hash ref!";
        return;
    }

    my $is_root = !defined $root;
    $root //= $self;

    #- unserialize first all relationships (resursively) and push some defered in a queue with everything needed to attach it with it's container
    my $rsrc = $self->result_source;
    my @defereds;
    my $relationships = $self->hrs_serializable_relationships;
    RELATION:
    for my $rel_name ( @$relationships ){
        my $related = delete $serialized->{$rel_name}
            or next RELATION;
        my $rel_info = $rsrc->relationship_info($rel_name);
        my $reverse_rel = $rsrc->reverse_relationship_info($rel_name);
        my $related_class = $rel_info->{class};
        my $unserializer = exists $rel_info->{attrs}{unserializer}
                 ? $rel_info->{attrs}{unserializer}
                 : ( $related_class->can('unserialize')
                    // \&unserialize )
                 ;
        $related = [ $related ] unless ref($related) eq 'ARRAY';
        RELATED:
        for my $serial ( @$related ){
            my $obj = $self
                        ->result_source
                        ->schema
                        ->resultset($related_class)
                        ->new_result({});
            push @defereds, sub{ 
                say "unserializing ", $rsrc->name, "->", $rel_name if DEBUG;
                $unserializer->($obj, $serial, $args, $root, $self) 
            };
            hrs_set_relationship( $self, $rel_name, $obj, $rel_info );
            #plus reverse relation(s)
            while(my ($rev_name, $rev_info) = each %$reverse_rel){
                hrs_set_relationship( $obj, $rev_name, $self, $rev_info );
            }
        }
    }
    #- unserialize $self attributs
    $self->set_columns( $serialized );
    # - process defered queue to fill prepared entities
    $_->() for @defereds;
    # - return toplevel entity (not stored yet)
    return $self;
}

=head2 hrs_set_relationship

Set a relationship between two ResultClass.

    $self->hrs_serializable_relationships($rel_name, $related);
    
=cut 
sub hrs_set_relationship{
    my ($self, $rel_name, $related, $rel_info) = @_;
    say "unserializing : set rel", $self->result_source->name, " -> ", $rel_name if DEBUG;
    $rel_info //=  $self->result_source->relationship_info($rel_name);
    if(($rel_info->{attrs}{accessor} || '') eq 'single'){
        say "hrs_set_relationship ", $rel_name, " set single value" if DEBUG;
        $self->{_relationship_data}{$rel_name} = $related;
    }
    else{
        say "hrs_set_relationship ", $rel_name, " pushing on array" if DEBUG;
        push @{$self->{_relationship_data}{$rel_name}}, $related;
    }
}

=head2 unserialize_rs

Should not be manipulated, reserved for internal usages.

=cut 
sub unserialize_rs{
    my ($rs,  $serialized, $args) = @_;
    $serialized = [ $serialized ] unless ref($serialized) eq 'ARRAY';
    my $unserializer = $rs->result_class->can('unserialize') // \&unserialize;
    my @deserialized = map{
        $unserializer->($rs->new({}), $_, $args)
    } @$serialized;
    return @deserialized if @$serialized > 1;
    return $deserialized[0];
}

package #hide the hack
    DBIx::Class::Helper::ResultSet::Seriliazer;
sub unserialize{ &DBIx::Class::Helper::Row::Serializer::unserialize_rs  }
require DBIx::Class::ResultSet;
DBIx::Class::ResultSet->load_components('+DBIx::Class::Helper::ResultSet::Seriliazer');

1;
__END__
=pod
=head1 Serialization

The serialisation will NOT serialize autoincrement columns, this is because unserialization will not works 
in most of the cases because of duplicated values.
Relations beteween objects are kept using a tree structure using embedded hashes and arrays.
A belongs_to is  not serialized by default but can be forced by specifying C<is_serializable => 1> in the
ResultClass definition.

=head1 BAD designed DB serialisation

Having a bad/specific designed database, it can be hard to serialize and unserialize automagically.
For the sake of exemple:

	Script
		-> defs: @Definition
			<- script: Script
			-> referers: @Variable
				<- script: Script
				-> definition: Definition
		-> vars: @Variable[]
				<- script: Script
				-> definition: Definition

In this exemple, a Definition is referenced by a Script and by Variable(s) and a Variable is 
referenced by a Script and by a Definition.

Producing a serialization form that can keep track of this kind of relations is a bit hard. It is possible 
to ignore some columns or relations from being serialized by specifying C<is_serializable => 0> in the
ResultClass definition. You can write custom serializer and unserializer for your ResultClass or by relation.
It is also possible to customize unserialization priorities for relationships by specifying 
C<unserialization_priority => -1> in the ResultClass definition, relationships will be processed in the priority order (numeric).

=head1 TODO

Provide hooks to access has_to_many relations within a custom unserializer, actualy it is needed to look in "_relationship_data" 
internal DBIx::Class::Row object.

=cut