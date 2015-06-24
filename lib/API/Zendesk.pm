package API::Zendesk;
# ABSTRACT: API interface to Zendesk
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

=head1 NAME

API::Zendesk

=head1 DESCRIPTION

Manage Zendesk connection, get tickets etc.  This is a work-in-progress - we have only written
the access methods we have used so far, but as you can see, it is a good template to extend
for all remaining API endpoints.  I'm totally open for any pull requests! :)

This module uses MooseX::Log::Log4perl for logging - be sure to initialize!

=head1 ATTRIBUTES

=cut

with "MooseX::Log::Log4perl";

=over 4

=item cache

Optional.

Provided by MooseX::WithX - optionally pass a Cache::FileCache object to cache and avoid unnecessary requests

=cut

# Unfortunately it is necessary to define the cache type to be expected here with 'backend'
# TODO a way to be more generic with cache backend would be better
with 'MooseX::WithCache' => {
    backend => 'Cache::FileCache',
};

=item zendesk_token

Required.

=cut
has 'zendesk_token' => (
    is          => 'ro',
    isa         => 'Str',
    required    => 1,
    );

=item zendesk_username

Required.

=cut
has 'zendesk_username' => (
    is          => 'ro',
    isa         => 'Str',
    required    => 1,
    );
	

=item zendesk_api_url

Required.

=cut
has 'zendesk_api_url' => (
    is		=> 'ro',
    isa		=> 'Str',
    required	=> 1,
    );

=item user_agent

Optional.  A new LWP::UserAgent will be created for you if you don't already have one you'd like to reuse.

=cut

has 'user_agent' => (
    is		=> 'ro',
    isa		=> 'LWP::UserAgent',
    required	=> 1,
    lazy	=> 1,
    builder	=> '_build_user_agent',

    );

has '_zendesk_credentials' => (
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
    $ua->default_header( 'Authorization'    => "Basic " . $self->_zendesk_credentials );
    return $ua;
}

sub _build_zendesk_credentials {
    my $self = shift;
    return encode_base64( $self->zendesk_username . "/token:" . $self->zendesk_token );
}

=back

=head1 METHODS

=over 4

=item init

Create the user agent and credentials.  As these are built lazily, initialising manually can avoid
errors thrown when building them later being silently swallowed in try/catch blocks.

=cut

sub init {
    my $self = shift;
    my $ua = $self->user_agent;
    my $credentials = $self->_zendesk_credentials;
}

=item get_incremental_tickets

Access the L<Incremental Ticket Export|https://developer.zendesk.com/rest_api/docs/core/incremental_export#incremental-ticket-export> interface

!! Broken !!

=cut
sub get_incremental_tickets {
    my ( $self, %params ) = validated_hash(
        \@_,
        size        => { isa    => 'Int', optional => 1 },
    );
    my $path = '/incremental/ticket_events.json';
    my @results = $self->_paged_get_request_from_api(
        field   => '???', # <--- TODO
        method  => 'get',
	path    => $path,
        size    => $params{size},
        );

    $self->log->debug( "Got " . scalar( @results ) . " results from query" );
    return @results;

}

=item search

Access the L<Search|https://developer.zendesk.com/rest_api/docs/core/search> interface

Parameters

=over 4

=item query

Required.  Query string

=item sort_by

Optional. Default: "updated_at"

=item sort_order

Optional. Default: "desc"

=item size

Optional.  Integer indicating the number of entries to return.  The number returned may be slightly larger (paginating will stop when this number is exceeded).

=back

Returns array of results.

=cut
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

    my %request_params = (
        field   => 'results',
        method  => 'get',
	path    => $path,
    );
    $request_params{size} = $params{size} if( $params{size} );
    my @results = $self->_paged_get_request_from_api( %request_params );
    # TODO - cache results if tickets, users or organizations

    $self->log->debug( "Got " . scalar( @results ) . " results from query" );
    return @results;
}

=item get_comments_from_ticket

Access the L<List Comments|https://developer.zendesk.com/rest_api/docs/core/ticket_comments#list-comments> interface

Parameters

=over 4

=item ticket_id

Required.  The ticket id to query on.

=back

Returns an array of comments

=cut
sub get_comments_from_ticket {
    my ( $self, %params ) = validated_hash(
        \@_,
        ticket_id	=> { isa    => 'Int' },
    );

    my $path = '/tickets/' . $params{ticket_id} . '/comments.json';
    my @comments = $self->_paged_get_request_from_api(
            method  => 'get',
	    path    => $path,
            field   => 'comments',
	);
    $self->log->debug( "Got " . scalar( @comments ) . " comments" );
    return @comments;
}

=item download_attachment

Download an attachment.

Parameters

=over 4

=item attachment

Required.  An attachment HashRef as returned as part of a comment.

=item dir

Directory to download to

=item force

Force overwrite if item already exists

=back

Returns path to the downloaded file

=cut

sub download_attachment {
    my ( $self, %params ) = validated_hash(
        \@_,
        attachment	=> { isa	=> 'HashRef' },
	dir	        => { isa	=> 'Str' },
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

=item add_response_to_ticket

Shortcut to L<Updating Tickets|https://developer.zendesk.com/rest_api/docs/core/tickets#updating-tickets> specifically for adding a response.

=over 4

=item ticket_id

Required.  Ticket to add response to

=item public

Optional.  Default: 0 (not public).  Set to "1" for public response

=item response

Required.  The text to be addded to the ticket as response.

=back

Returns response HashRef

=cut
sub add_response_to_ticket {
    my ( $self, %params ) = validated_hash(
        \@_,
        ticket_id	=> { isa    => 'Int' },
	public		=> { isa    => 'Bool', optional => 1, default => 0 },
	response	=> { isa    => 'Str' },
    );

    my $body = {
	"ticket" => {
	    "comment" => {
		"public"    => $params{public},
		"body"	    => $params{response},
	    }
	}
    };
    return $self->update_ticket(
        body        => $body,
        ticket_id   => $params{ticket_id},
        );

}

=item update_ticket

Access L<Updating Tickets|https://developer.zendesk.com/rest_api/docs/core/tickets#updating-tickets> interface.

=over 4

=item ticket_id

Required.  Ticket to add response to

=item body

Required.  HashRef of valid parameters - see link above for details.

=back

Returns response HashRef

=cut
sub update_ticket {
    my ( $self, %params ) = validated_hash(
        \@_,
        ticket_id	=> { isa    => 'Int' },
	body		=> { isa    => 'HashRef' },
    );

    my $encoded_body = encode_json( $params{body} );
    $self->log->trace( "Submitting:\n" . $encoded_body );
    my $response = $self->_request_from_api(
            method  => 'put',
	    path    => '/tickets/' . $params{ticket_id} . '.json',
	    body    => $encoded_body,
	);
    return $response;
}

=item get_ticket

Access L<Getting Tickets|https://developer.zendesk.com/rest_api/docs/core/tickets#getting-tickets> interface.

=over 4

=item ticket_id

Required.  Ticket to get

=item no_cache

Disable cache get/set for this operation

=back

Returns ticket HashRef

=cut
sub get_ticket {
    my ( $self, %params ) = validated_hash(
        \@_,
        ticket_id	=> { isa    => 'Int' },
        no_cache        => { isa    => 'Bool', optional => 1 }
    );
    
    # Try and get the info from the cache
    my $ticket;
    $ticket = $self->cache_get( 'ticket-' . $params{ticket_id} ) unless( $params{no_cache} );
    if( not $ticket ){
	$self->log->debug( "Ticket info not cached, requesting fresh: $params{ticket_id}" );
	my $info = $self->_request_from_api(
            method  => 'get',
	    path    => '/tickets/' . $params{ticket_id} . '.json',
	);
	
	if( not $info or not $info->{ticket} ){
	    $self->log->logdie( "Could not get ticket info for ticket: $params{ticket_id}" );
	}
        $ticket = $info->{ticket};
	# Add it to the cache so next time no web request...
	$self->cache_set( 'ticket-' . $params{ticket_id}, $ticket ) unless( $params{no_cache} );
    }
    return $ticket;
}

=item get_organizationt

Get a single organization by accessing L<Getting Organizations|https://developer.zendesk.com/rest_api/docs/core/organizations#list-organizations>
interface with a single organization_id.  The get_many_organizations interface detailed below is more efficient for getting many organizations
at once.

=over 4

=item organization_id

Required.  Organization id to get

=item no_cache

Disable cache get/set for this operation

=back

Returns organization HashRef

=cut
sub get_organization {
    my ( $self, %params ) = validated_hash(
        \@_,
        organization_id	=> { isa    => 'Int' },
        no_cache        => { isa    => 'Bool', optional => 1 }
    );
    
    my $organization;
    $organization = $self->cache_get( 'organization-' . $params{organization_id} ) unless( $params{no_cache} );
    if( not $organization ){
	$self->log->debug( "Organization info not in cache, requesting fresh: $params{organization_id}" );
	my $info = $self->_request_from_api(
            method  => 'get',
	    path    => '/organizations/' . $params{organization_id} . '.json',
	);
	if( not $info or not $info->{organization} ){
	    $self->log->logdie( "Could not get organization info for organization: $params{organization_id}" );
	}
        $organization = $info->{organization};

	# Add it to the cache so next time no web request...
	$self->cache_set( 'organization-' . $params{organization_id}, $organization ) unless( $params{no_cache} );
    }
    return $organization;
}

=item get_many_organizations

=over 4

=item organization_ids

Required.  ArrayRef of organization ids to get

=item no_cache

Disable cache get/set for this operation

=back

Returns an array of organization HashRefs

=cut
#get data about multiple organizations.
sub get_many_organizations {
    my ( $self, %params ) = validated_hash(
        \@_,
        organization_ids    => { isa    => 'ArrayRef' },
        no_cache            => { isa    => 'Bool', optional => 1 }
    );
    
    # First see if we already have any of the organizations in our cache - less to get
    my @organizations;
    my @get_organizations;
    foreach my $org_id ( @{ $params{organization_ids} } ){
        my $organization;
        $organization = $self->cache_get( 'organization-' . $org_id ) unless( $params{no_cache} );
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
	my @result= $self->_paged_get_request_from_api(
	    field   => 'organizations',
            method  => 'get',
	    path    => '/organizations/show_many.json?ids=' . join( ',', @get_organizations ),
	);
        foreach( @result ){
            $self->log->debug( "Writing organization to cache: $_->{id}" );
            $self->cache_set( 'organization-' . $_->{id}, $_ ) unless( $params{no_cache} );
            push( @organizations, $_ );
        }
    }
    return @organizations;
}


=item update_organization

Use the L<Update Organization|https://developer.zendesk.com/rest_api/docs/core/organizations#update-organization> interface.

=over 4

=item organization_id

Required.  Organization id to update

=item details

Required.  HashRef of the details to be updated.

=item no_cache

Disable cache set for this operation

=back

returns the 
=cut
sub update_organization {
    my ( $self, %params ) = validated_hash(
        \@_,
	organization_id	=> { isa    => 'Int' },
	details	        => { isa    => 'HashRef' },
        no_cache        => { isa    => 'Bool', optional => 1 }
    );

    my $body = {
	"organization" =>
	    $params{details}
    };

    my $encoded_body = encode_json( $body );
    $self->log->trace( "Submitting:\n" . $encoded_body );
    my $response = $self->_request_from_api(
        method  => 'put',
	    path    => '/organizations/' . $params{organization_id} . '.json',
	    body    => $encoded_body,
	);
    if( not $response or not $response->{organization}{id} == $params{organization_id} ){
	$self->log->logdie( "Could not update organization: $params{organization_id}" );
    }

    $self->cache_set( 'organization-' . $params{organization_id}, $response->{organization} ) unless( $params{no_cache} );

    return $response->{organization};
}

=item list_organization_users

Use the L<List Users|https://developer.zendesk.com/rest_api/docs/core/users#list-users> interface.

=over 4

=item organization_id

Required.  Organization id to get users from

=item no_cache

Disable cache set/get for this operation

=back

Returns array of users

=cut
sub list_organization_users {
    my ( $self, %params ) = validated_hash(
        \@_,
        organization_id	=> { isa    => 'Int' },
        no_cache        => { isa    => 'Bool', optional => 1 }
    );

    my $users_arrayref;
    $users_arrayref = $self->cache_get( 'organization-users-' . $params{organization_id} ) unless( $params{no_cache} );
    my @users;
    if( $users_arrayref ){
        @users = @{ $users_arrayref };
        $self->log->debug( sprintf "Users from cache for organization: %u", scalar( @users ), $params{organization_id} );
    }else{
        $self->log->debug( "Requesting users fresh for organization: $params{organization_id}" );
        @users = $self->_paged_get_request_from_api(
            field   => 'users',
            method  => 'get',
            path    => '/organizations/' . $params{organization_id} . '/users.json',
        );

	$self->cache_set( 'organization-users-' . $params{organization_id}, \@users ) unless( $params{no_cache} );
    }
    $self->log->debug( sprintf "Got %u users for organization: %u", scalar( @users ), $params{organization_id} );

    return @users;
}

=item update_user

Use the L<Update User|https://developer.zendesk.com/rest_api/docs/core/users#update-user> interface.

=over 4

=item user_id

Required.  User id to update

=item details

Required.  HashRef of the details to be updated.

=item no_cache

Disable cache set for this operation

=back

returns the
=cut
sub update_user {
    my ( $self, %params ) = validated_hash(
        \@_,
        user_id         => { isa    => 'Int' },
        details         => { isa    => 'HashRef' },
        no_cache        => { isa    => 'Bool', optional => 1 }
    );

    my $body = {
        "user" =>
            $params{details}
    };

    my $encoded_body = encode_json( $body );
    $self->log->trace( "Submitting:\n" . $encoded_body );
    my $response = $self->_request_from_api(
        method  => 'put',
            path    => '/users/' . $params{user_id} . '.json',
            body    => $encoded_body,
        );
    if( not $response or not $response->{user}{id} == $params{user_id} ){
        $self->log->logdie( "Could not update user: $params{user_id}" );
    }

    $self->cache_set( 'user-' . $params{user_id}, $response->{user} ) unless( $params{no_cache} );

    return $response->{user};
}

=item list_user_assigned_tickets

Use the L<List assigned tickets|https://developer.zendesk.com/rest_api/docs/core/tickets#listing-tickets> interface.

=over 4

=item user_id

Required.  User id to get assigned tickets from

=item no_cache

Disable cache set/get for this operation

=back

Returns array of tickets

=cut
sub list_user_assigned_tickets {
    my ( $self, %params ) = validated_hash(
        \@_,
        user_id	=> { isa    => 'Int' },
        no_cache        => { isa    => 'Bool', optional => 1 }
    );

    my $tickets_arrayref;
    $tickets_arrayref = $self->cache_get( 'user-assigned -tickets' . $params{user_id} ) unless( $params{no_cache} );
    my @tickets;
    if( $tickets_arrayref ){
        @tickets = @{ $tickets_arrayref };
        $self->log->debug( sprintf "Tickets from cache for user: %u", scalar( @tickets ), $params{user_id} );
    }else{
        $self->log->debug( "Requesting tickets fresh for user: $params{user_id}" );
        @tickets = $self->_paged_get_request_from_api(
            field   => 'tickets',
            method  => 'get',
            path    => '/users/' . $params{user_id} . '/tickets/assigned.json',
        );

	$self->cache_set( 'user-assigned -tickets' . $params{user_id}, \@tickets ) unless( $params{no_cache} );
    }
    $self->log->debug( sprintf "Got %u assigned tickets for user: %u", scalar( @tickets ), $params{user_id} );

    return @tickets;
}

sub _paged_get_request_from_api {
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
        $response = $self->_request_from_api(
            method  => 'get',
	    path    => $params{path} . ( $params{path} =~ m/\?/ ? '&' : '?' ) . 'page=' . $page,
	);
	
	push( @results, @{ $response->{$params{field} } } );
	$page++;
      }while( $response->{next_page} and ( not $params{size} or scalar( @results ) < $params{size} ) );

    return @results;
}


sub _request_from_api {
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
    my $retry = 1;
    my $retryDelay = 1;
    do{
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
        if( not $response->is_success ){
            if(  $response->code == 503 ){
                # Try to decode the response
                try{
                     my $data = decode_json( encode( 'utf8', $response->decoded_content ) );
                     if( $data->{description} and $data->{description} =~ m/Please try again in a moment/ ){
                         $self->log->warn( "Received a 503 (description: Please try again in a moment)... going to backoff and retry!" );
                         $retry = 0;
                     }
                }catch{
                    $self->log->error( $_ );
                    $retry = 0;
                };
            }elsif( $response->code == 429 ){
		#get Retry-After header and use that for the retry time
		$retryDelay = $response->header('Retry-After');
		$self->log->warn( "Received a 429 (Too Many Requests) response... going to backoff and retry in $retryDelay seconds!" );
            }else{
                $retry = 0;
            }
            if( $retry == 1 ){
                $response = undef;
                sleep( $retryDelay );
            }
        }
    }while( $retry and not $response );
    if( not $response->is_success ){
	$self->log->logdie( "Zendesk API Error: http status:".  $response->code .' '.  $response->message . ' Content: ' . $response->content);
    }
    $self->log->trace( "Zendesk API Error: http status:".  $response->code .' '.  $response->message . ' Content: ' . $response->content);

    #my $json_string = $response->decoded_content();

    return decode_json( encode( 'utf8', $response->decoded_content ) );
}


1;

=back

=head1 COPYRIGHT

Copyright 2015, Robin Clarke 

=head1 AUTHOR

Robin Clarke <robin@robinclarke.net>

Jeremy Falling <projects@falling.se>

