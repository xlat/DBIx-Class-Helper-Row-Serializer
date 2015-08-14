use utf8;
use Test::More;
use Test::DBIC;
use Storable qw(dclone);
#~ use Data::Dumper;
use Modern::Perl;

use_ok 'DBIx::Class::Helper::Row::Serializer';
require_ok 'DBD::SQLite';

my $schema;

package MyApp::Schema::Script;
use base  'DBIx::Class';
__PACKAGE__->load_components(qw( Core Helper::Row::Serializer ));
__PACKAGE__->table('script');
__PACKAGE__->add_columns(
		id 	=> { data_type => 'int', is_auto_increment => 1 },
		name => { data_type => 'varchar', size => 50, is_nullable => 0},
	);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many( defs => 'MyApp::Schema::Definition', 'script_id');
__PACKAGE__->has_many( vars => 'MyApp::Schema::Variable', 'script_id'  , { unserialization_priority => -1 });
sub schema{ $schema }
1;

package MyApp::Schema::Definition;
use base  'DBIx::Class';
__PACKAGE__->load_components(qw( Core Helper::Row::Serializer ));
__PACKAGE__->table('definition');
__PACKAGE__->add_columns(
		id 	=> { data_type => 'int', is_auto_increment => 1 },
		name => { data_type => 'varchar', size => 50, is_nullable => 0},
		script_id => { data_type => 'int', is_nullable => 0 },
	);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many( referers => 'MyApp::Schema::Variable', 'definition_id', 
						{ is_serializable => 0 });	#do not serialize referers
__PACKAGE__->belongs_to( script => 'MyApp::Schema::Script', 'script_id' );
sub schema{ $schema }
1;

package MyApp::Schema::Variable;
use base  'DBIx::Class';
__PACKAGE__->load_components(qw( Core Helper::Row::Serializer ));
__PACKAGE__->table('variable');
__PACKAGE__->add_columns(
		id 	=> { data_type => 'int', is_auto_increment => 1 },
		value => { data_type => 'varchar', size => 20, is_nullable => 1},
		script_id => { data_type => 'int', is_nullable => 0 },
		definition_id => { data_type => 'int', is_nullable => 0 },
	);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to( script => 'MyApp::Schema::Script', 'script_id' );
__PACKAGE__->belongs_to( definition => 'MyApp::Schema::Definition', 'definition_id', 
	#force (un)serialisation with custom syntax
	{ 
		is_serializable => 1,
		serializer 	 => sub{
			my ($definition, $args, $script, $variable) = @_;
			return { __link__ => $definition->name };
		},
		unserializer => sub{
			my ($self, $serialised_def, $args, $script, $variable) = @_;
			for( @{$script->{_relationship_data}{defs}} ){
				if($_->name eq $serialised_def->{__link__}){
					#~ say "variable.definition custom unserializer";
					$variable->definition( $_ );
					return $_;
				}
			}
		},
	} );
sub schema{ $schema }
1;

package main;

#~ sub _dumper_hook {
  #~ $_[0] = bless {
    #~ %{ $_[0] },
    #~ result_source => undef,
    #~ _result_source => undef,
  #~ }, ref($_[0]);
#~ }

#~ local $Data::Dumper::Freezer = '_dumper_hook';
#~ *MyApp::Schema::Script::_dumper_hook 	= \&_dumper_hook;
#~ *MyApp::Schema::Definition::_dumper_hook= \&_dumper_hook;
#~ *MyApp::Schema::Variable::_dumper_hook 	= \&_dumper_hook;

$schema = Test::DBIC->init_schema(
        existing_namespace => 'MyApp::Schema',
        sqlt_deploy => 1,
        'sample_data' => [
            Script => [
                ['id', 'name'],
                [1, 'my script'],
            ],
            Definition => [
                ['id', 'name', 'script_id'],
                [10, 'myType1', 1],
                [11, 'myType2', 1],
            ],
            Variable => [
                ['id', 'value', 'script_id', 'definition_id'],
                [20, 'myvalue1', 1, 10],
                [21, 'myvalue2', 1, 11],
                #~ [22, 'myvalue3', 1, 10],	#a duplicated should not de unserialized twice just ignored.
            ],
        ],
    );

my @scripts		= $schema->resultset('Script')->all;
my @definitions	= $schema->resultset('Definition')->all;
my @variables 	= $schema->resultset('Variable')->all;

is @scripts, 	1, 'scripts records count';
is @definitions,2, 'definitions records count';
is @variables, 	2, 'variables records count';

my @expecteds =  (
   {
     'name' => 'my script',
     'defs' => [
                 { 'name' => 'myType1', },
                 { 'name' => 'myType2', },
               ],
	 'vars' => [
				 { 'value' => 'myvalue1', 'definition' => { '__link__' => 'myType1' } },
				 { 'value' => 'myvalue2', 'definition' => { '__link__' => 'myType2' } },
	 ],
   },
 );

my $i = 0;

SCRIPTS:
for my $script ( @scripts ){
	my $serial = $script->serialize;
    is_deeply $serial, $expecteds[$i++], "script\#$i serialization";
		#~ or diag( Dumper($serial) );
}
my $script1 = $schema->resultset('Script')->unserialize( dclone( $expecteds[0] ) );
is ref($script1), 'MyApp::Schema::Script', 'unserialize result class';
is ref($script1->insert), 'MyApp::Schema::Script', 'insert a new Script';
my $reserialize = $script1->serialize;
my $test = is_deeply $reserialize, $expecteds[0], "unserialized & reserialiazed";

done_testing;