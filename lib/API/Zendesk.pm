package API::Zendesk;
use Moose;
use MooseX::Params::Validate;
use MooseX::WithCache;
use File::Spec::Functions; # catfile
use MIME::Base64;
use File::Path qw/make_path/;
use LWP::UserAgent;
use JSON::MaybeXS;
use YAML;
use URI::Encode qw/uri_encode/;
use Encode;

with "MooseX::Log::Log4perl";

# Unfortunately it is necessary to define the cache type to be expected here with 'backend'
# TODO a way to be more generic with cache backend would be better
with 'MooseX::WithCache' => {
    backend => 'Cache::FileCache',
};

has 'zendesk_token' => (
    is          => 'ro',
    isa         => 'Str',
    required    => 1,
    );

has 'zendesk_username' => (
    is          => 'ro',
    isa         => 'Str',
    required    => 1,
    );
	
has 'backoff_time' => (
    is          => 'ro',
    isa         => 'Int',
    required    => 1,
    default     => 10,
    );

has 'zendesk_api_url' => (
    is		=> 'ro',
    isa		=> 'Str',
    required	=> 1,
    default	=> 'https://elasticsearch.zendesk.com/api/v2',
    );

has 'user_agent' => (
    is		=> 'ro',
    isa		=> 'LWP::UserAgent',
    required	=> 1,
    lazy	=> 1,
    builder	=> '_build_user_agent',

    );

has 'zendesk_credentials' => (
    is		=> 'ro',
    isa		=> 'Str',
    required	=> 1,
    lazy	=> 1,
    builder	=> '_build_zendesk_credentials',
    );

sub _build_user_agent {
    my $self = shift;
    $self->log->debug( "Building zendesk useragent" );
    my $ua = LWP::UserAgent->new(
	keep_alive	=> 1
    );
    $ua->default_header( 'Content-Type'	    => "application/json" );
    $ua->default_header( 'Accept'	    => "application/json" );
    $ua->default_header( 'Authorization'    => "Basic " . $self->zendesk_credentials );
    return $ua;
}

sub _build_zendesk_credentials {
    my $self = shift;
    return encode_base64( $self->zendesk_username . "/token:" . $self->zendesk_token );
}

sub init {
    my $self = shift;
    my $ua = $self->user_agent;
    my $credentials = $self->zendesk_credentials;
}

sub get_incremental_tickets {
    my ( $self, %params ) = validated_hash(
        \@_,
        size        => { isa    => 'Int', optional => 1 },
    );
    my $path = '/incremental/ticket_events.json';
    my @results = $self->paged_get_request_from_api(
        field   => '???', # <--- TODO
        method  => 'get',
	path    => $path,
        size    => $params{size},
        );

    $self->log->debug( "Got " . scalar( @results ) . " results from query" );
    return @results;

}

sub search {
    my ( $self, %params ) = validated_hash(
        \@_,
        query	    => { isa    => 'Str' },
        sort_by     => { isa    => 'Str', optional => 1, default => 'updated_at' },
        sort_order  => { isa    => 'Str', optional => 1, default => 'desc' },
        size        => { isa    => 'Int', optional => 1 },
    );
    $self->log->debug( "Searching: $params{query}" );
    my $path = '/search.json?query=' . uri_encode( $params{query} ) . "&sort_by=$params{sort_by}&sort_order=$params{sort_order}";

    my @results = $self->paged_get_request_from_api(
        field   => 'results',
        method  => 'get',
	path    => $path,
        size    => $params{size},
        );

    $self->log->debug( "Got " . scalar( @results ) . " results from query" );
    return @results;
}

sub get_diagnostics_from_ticket {
    my ( $self, %params ) = validated_hash(
        \@_,
        ticket_id	=> { isa    => 'Int' },
    );
    my @comments = $self->get_comments_from_ticket(
	ticket_id   => $params{ticket_id},
	);

    my @attachments;
    foreach my $comment( @comments ){
        push( @attachments, @{ $comment->{attachments} } );
    }
    return @attachments;
}

sub get_comments_from_ticket {
    my ( $self, %params ) = validated_hash(
        \@_,
        ticket_id	=> { isa    => 'Int' },
    );

    my $path = '/tickets/' . $params{ticket_id} . '/comments.json';
    my @comments = $self->paged_get_request_from_api(
            method  => 'get',
	    path    => $path,
            field   => 'comments',
	);
    $self->log->debug( "Got " . scalar( @comments ) . " comments" );
    return @comments;
}

sub download_attachment {
    my ( $self, %params ) = validated_hash(
        \@_,
        attachment	=> { isa	=> 'HashRef' },
	dir	        => { isa	=> 'Str' },
	ticket_id	=> { isa	=> 'Int' },
	force		=> { isa	=> 'Bool', optional => 1 },
    );
    
    my $target = catfile( $params{dir}, $params{attachment}{file_name} ); 
    $self->log->debug( "Downloading attachment ($params{attachment}{size} bytes)\n" .
        "    URL: $params{attachment}{content_url}\n    target: $target" );

    # Deal with target already exists
    # TODO Check if the local size matches the size which we should be downloading
    if( -f $target ){
	if( $params{force} ){
	    $self->log->info( "Target already exist, but downloading again because force enabled: $target" );
	}else{
	    $self->log->info( "Target already exist, not overwriting: $target" );
	    return $target;
	}
    }
    
    my $response = $self->user_agent->get( 
	$params{attachment}{content_url},
	':content_file'	=> $target, 
	# So we don't get a http 406 error
	'Content-Type'	=> '',
	'Accept'	=> '',
	);
    if( not $response->is_success ){
	$self->log->logdie( "Zendesk API Error: http status:".  $response->code .' '.  $response->message );
    }
    return $target;
}


sub add_response_to_ticket {
    my ( $self, %params ) = validated_hash(
        \@_,
        ticket_id	=> { isa    => 'Int' },
	public		=> { isa    => 'Bool', optional => 1, default => 0 },
	response	=> { isa    => 'Str' },
	test		=> { isa    => 'Bool', optional => 1 },
    );

    if( $params{test} ){
	$self->log->warn( "Running in test, not really connecting with Zendesk" );
	# TODO - what does a real response look like?
	return { 'test' => 1 };
    }
	
    my $body = {
	"ticket" => {
	    "comment" => {
		"public"    => $params{public},
		"body"	    => $params{response},
	    }
	}
    };
    my $encoded_body = encode_json( $body );
    #$self->log->debug( "Submitting:\n" . $encoded_body );
    my $response = $self->request_from_api(
            method  => 'put',
	    path    => '/tickets/' . $params{ticket_id} . '.json',
	    body    => $encoded_body,
	);
    return $response;
}

# Get ticket information
sub get_ticket {
    my ( $self, %params ) = validated_hash(
        \@_,
        ticket_id	=> { isa    => 'Int' },
	test		=> { isa    => 'Bool', optional => 1 },
    );
    if( $params{test} ){
	$self->log->warn( "Running in test, not really connecting with Zendesk" );
	# TODO - what does a real response look like?
	return { 'test' => 1 };
    }

    # Try and get the info from the cache
    my $info = $self->cache_get( 'ticket-' . $params{ticket_id} );
    if( not $info ){
	$self->log->debug( "Ticket info not cached, requesting fresh: $params{ticket_id}" );
	$info = $self->request_from_api(
            method  => 'get',
	    path    => '/tickets/' . $params{ticket_id} . '.json',
	);
	
	if( not $info ){
	    $self->log->logdie( "Could not get ticket info for ticket: $params{ticket_id}" );
	}
	# Add it to the cache so next time no web request...
	$self->cache_set( 'ticket-' . $params{ticket_id}, $info );
    }
    return $info->{ticket};
}

# See the get_many_organizations below to efficiently get many organizations with one call
sub get_organization {
    my ( $self, %params ) = validated_hash(
        \@_,
        organization_id	=> { isa    => 'Int' },
	test		=> { isa    => 'Bool', optional => 1},
    );
    if( $params{test} ){
	$self->log->warn( "Running in test, not really connecting with Zendesk" );
	return { 'test' => 1 };
    }
    my $info = $self->cache_get( 'organization-' . $params{organization_id} );
    if( not $info ){
	$self->log->debug( "Organization info not in cache, requesting fresh: $params{organization_id}" );
	$info = $self->request_from_api(
            method  => 'get',
	    path    => '/organizations/' . $params{organization_id} . '.json',
	);

	# Add it to the cache so next time no web request...
	$self->cache_set( 'organization-' . $params{organization_id}, $info );
    }
    return $info->{organization};
}

# There are many valid options for the request hash, some of which are documented here:
# https://developer.zendesk.com/rest_api/docs/core/organizations#update-organization
# example request (submit as perl hashref here):   {"organization_fields":{"temp_lead": "somedude_temp_lead"}}
sub set_organization {
    my ( $self, %params ) = validated_hash(
        \@_,
	organization_id	=> { isa    => 'Int' },
	request	        => { isa    => 'HashRef' },
	test		=> { isa    => 'Bool', optional => 1 },
    );

    if( $params{test} ){
	$self->log->warn( "Running in test, not really connecting with Zendesk" );
	# TODO - what does a real response look like?
	return { 'test' => 1 };
    }

    my $body = {
	"organization" =>
	    $params{request}
    };

    my $encoded_body = encode_json( $body );
    $self->log->trace( "Submitting:\n" . $encoded_body );
    my $response = $self->request_from_api(
        method  => 'put',
	    path    => '/organizations/' . $params{organization_id} . '.json',
	    body    => $encoded_body,
	);
    # TODO validate response for success (returns all org data)

    # Update the cache for this organization
    $self->cache_set( 'organization-' . $params{organization_id}, $response );

    return $response;
}

#get every user under an organization
sub list_organization_users {
    my ( $self, %params ) = validated_hash(
        \@_,
        organization_id	=> { isa    => 'Int' },
	test		=> { isa    => 'Bool', optional => 1},
    );
    if( $params{test} ){
        $self->log->warn( "Running in test, not really connecting with Zendesk" );
        return { 'test' => 1 };
    }

    my $users_arrayref  = $self->cache_get( 'organization-users-' . $params{organization_id} );
    my @users;
    if( $users_arrayref ){
        @users = @{ $users_arrayref };
        $self->log->debug( sprintf "Users from cache for organization: %u", scalar( @users ), $params{organization_id} );
    }else{
        $self->log->debug( "Requesting users fresh for organization: $params{organization_id}" );
        @users = $self->paged_get_request_from_api(
            field   => 'users',
            method  => 'get',
            path    => '/organizations/' . $params{organization_id} . '/users.json',
        );


	# Add it to the cache so next time no web request...
	$self->cache_set( 'organization-users-' . $params{organization_id}, \@users );
    }
    $self->log->debug( sprintf "Got %u users for organization: %u", scalar( @users ), $params{organization_id} );

    return @users;
}

#get data about multiple organizations.
sub get_many_organizations {
    my ( $self, %params ) = validated_hash(
        \@_,
        organization_ids  => { isa    => 'ArrayRef' },
	test	          => { isa    => 'Bool', optional => 1},
    );
    if( $params{test} ){
	$self->log->warn( "Running in test, not really connecting with Zendesk" );
	return { 'test' => 1 };
    }
    
    # First see if we already have any of the organizations in our cache - less to get
    my @organizations;
    my @get_organizations;
    foreach my $org_id ( @{ $params{organization_ids} } ){
        my $organization = $self->cache_get( 'organization-' . $org_id );
        if( $organization ){
            $self->log->debug( "Found organization in cache: $org_id" );
            push( @organizations, $organization );
        }else{
            push( @get_organizations, $org_id );
        }
    }

    # If there are any organizations remaining, get these with a single request
    if( scalar( @get_organizations ) > 0 ){
	$self->log->debug( "Organizations not in cache, requesting fresh: " . join( ',', @get_organizations ) );
	my @result= $self->paged_get_request_from_api(
	    field   => 'organizations',
            method  => 'get',
	    path    => '/organizations/show_many.json?ids=' . join( ',', @get_organizations ),
	);
        foreach( @result ){
            $self->log->debug( "Writing organization to cache: $_->{id}" );
            $self->cache_set( 'organization-' . $_->{id}, $_ );
            push( @organizations, $_ );
        }
    }
    return @organizations;
}

sub paged_get_request_from_api {
    my ( $self, %params ) = validated_hash(
        \@_,
        method	=> { isa => 'Str' },
	path	=> { isa => 'Str' },
        field   => { isa => 'Str' },
        size    => { isa => 'Int', optional => 1 },
        body    => { isa => 'Str', optional => 1 },
    );
    my @results;
    my $page = 1;
    my $response = undef;
    do{
        $response = $self->request_from_api(
            method  => 'get',
	    path    => $params{path} . ( $params{path} =~ m/\?/ ? '&' : '?' ) . 'page=' . $page,
	);
	
	push( @results, @{ $response->{$params{field} } } );
	$page++;
      }while( $response->{next_page} and ( not $params{size} or scalar( @results ) < $params{size} ) );

    return @results;
}


sub request_from_api {
    my ( $self, %params ) = validated_hash(
        \@_,
        method	=> { isa => 'Str' },
	path	=> { isa => 'Str' },
        body    => { isa => 'Str', optional => 1 },
    );
    my $url = $self->zendesk_api_url . $params{path};
    $self->log->debug( "Requesting from Zendesk ($params{method}): $url" );
    my $response;
    my $retry_count = 0;
    do{
        if( $retry_count > 0 ){
            sleep( 10 );
        }
        if( $params{method} =~ m/^get$/i ){
            $response = $self->user_agent->get( $url );

        }elsif( $params{method} =~ m/^put$/i ){
            if( $params{body} ){
                $response = $self->user_agent->put( $url,
                                                    Content => $params{body} );
            }else{
                $response = $self->user_agent->put( $url );
            }
        }else{
            $self->log->logdie( "Unsupported request method: $params{method}" );
        }
        if( not $response->is_success and $response->code == 429 ){
            $self->log->warn( "Received a 429 (Too Many Requests) response... going to retry in " . $self->backoff_time . " seconds" );
            $response = undef;
            sleep( $self->backoff_time );
        }
    }while( not $response );
    if( not $response->is_success ){
	$self->log->logdie( "Zendesk API Error: http status:".  $response->code .' '.  $response->message . ' Content: ' . $response->content);
    }
    $self->log->trace( "Zendesk API Error: http status:".  $response->code .' '.  $response->message . ' Content: ' . $response->content);

    #my $json_string = $response->decoded_content();

    return decode_json( encode( 'utf8', $response->decoded_content ) );
}


1;


# ABSTRACT: API interface to Zendesk

=head1 NAME

API::Zendesk

=head1 DESCRIPTION

Manage Zendesk connection, get tickets etc.


=head1 METHODS

=over 4


=back

=head1 COPYRIGHT

Copyright 2015, Robin Clarke @ Elastic

=head1 AUTHOR

Robin Clarke <robin.clarke@elastic.co>

