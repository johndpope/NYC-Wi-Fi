//
//  MapViewController.m
//  NYC Wi-Fi
//
//  Created by Kevin Wolkober on 8/28/12.
//  Copyright (c) 2012 Kevin Wolkober. All rights reserved.
//

#import "MapViewController.h"
#import "MapLocation.h"
#import "LocationInfo.h"
#import "LocationDetails.h"
#import "SMXMLDocument.h"
#import "PopoverViewController.h"
#import "UIBarButtonItem+WEPopover.h"
#import "WifiClusterAnnotationView.h"
#import "Reachability.h"

//mapview starting points
#define kCenterPointLatitude  40.746347
#define kCenterPointLongitude -73.978011
#define kSpanDeltaLatitude    5.5
#define kSpanDeltaLongitude   5.5

#define iphoneScaleFactorLatitude   9.0
#define iphoneScaleFactorLongitude  11.0

//#define nycOpenDataWifiLocationsXMLAddress  @"https://data.cityofnewyork.us/api/views/ehc4-fktp/rows.xml"

@implementation MapViewController
@synthesize mapView = _mapView;
@synthesize managedObjectContext = _managedObjectContext;
@synthesize backgroundMOC = _backgroundMOC;
@synthesize fetchedResultsController = _fetchedResultsController;
@synthesize filterPredicate = _filterPredicate;
@synthesize fetchedLocations = _fetchedLocations;
@synthesize selectedLocation = _selectedLocation;
@synthesize popoverButton = _popoverButton;
@synthesize searchBarButtonItem = _searchBarButtonItem;
@synthesize locateMeButtonItem = _locateMeButtonItem;
@synthesize searchBar = _searchBar;
@synthesize floatingController = _floatingController;
@synthesize popoverController, locationManager;

#pragma mark -
#pragma mark Map view delegate

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id <MKAnnotation>)annotation {
    
    if ([annotation isKindOfClass:[MapLocation class]]) {
        
        MapLocation *pin = (MapLocation *)annotation;
        
        MKAnnotationView *annotationView;
        
        if ([pin nodeCount] > 0) {
            pin.name = @"___";
            
            annotationView = (WifiClusterAnnotationView *) [mapView dequeueReusableAnnotationViewWithIdentifier:@"cluster"];
            
            if( !annotationView )
                annotationView = (WifiClusterAnnotationView *) [[WifiClusterAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:@"cluster"];
            
            if ([pin nodeCount] > 50) {
                annotationView.image = [UIImage imageNamed:@"red-cluster.png"];
            } else if ([pin nodeCount] > 25 && [pin nodeCount] < 50) {
                annotationView.image = [UIImage imageNamed:@"orange-cluster.png"];
            } else if ([pin nodeCount] > 10 && [pin nodeCount] < 25) {
                annotationView.image = [UIImage imageNamed:@"yellow-cluster.png"];
            } else {
                annotationView.image = [UIImage imageNamed:@"green-cluster.png"];
            }
        
            [(WifiClusterAnnotationView *)annotationView setClusterText:[NSString stringWithFormat:@"%i",[pin nodeCount]]];
            
            annotationView.canShowCallout = NO;
        } else {
            
            annotationView = [mapView dequeueReusableAnnotationViewWithIdentifier:@"pin"];
            
            if (!annotationView)
                annotationView = [[MKAnnotationView alloc] initWithAnnotation:annotation
                                                              reuseIdentifier:@"pin"];
            else
                annotationView.annotation = annotation;
            
            if ([pin.location.fee_type isEqualToString:@"Free"])
                annotationView.image = [UIImage imageNamed:@"wifi-pin.png"];
            else
                annotationView.image = [UIImage imageNamed:@"wifi-pin-fee.png"];

            annotationView.backgroundColor = [UIColor clearColor];
            UIButton *goToDetail = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
            annotationView.rightCalloutAccessoryView = goToDetail;
            annotationView.draggable = NO;
            annotationView.highlighted = NO;
            annotationView.canShowCallout = YES;
        }
        
        return annotationView;
    } else if ([annotation isKindOfClass:[SearchMapPin class]]) {
        MKPinAnnotationView *annotationView =
        (MKPinAnnotationView *)[_mapView dequeueReusableAnnotationViewWithIdentifier:@"search"];
        
        if (annotationView == nil) {
            annotationView = [[MKPinAnnotationView alloc]
                              initWithAnnotation:annotation
                              reuseIdentifier:@"search"];
        } else {
            annotationView.annotation = annotation;
        }
        
        annotationView.enabled = YES;
        annotationView.draggable = NO;
        annotationView.highlighted = NO;
        annotationView.canShowCallout = YES;
        
        return annotationView;
    }
    return nil;
}

- (void)mapView:(MKMapView *)mapView didSelectAnnotationView:(MKAnnotationView *)view
{
    if (![view isKindOfClass:[WifiClusterAnnotationView class]])
        return;
    
    CLLocationCoordinate2D centerCoordinate = [(MapLocation *)view.annotation coordinate];
    
    MKCoordinateSpan newSpan =
    MKCoordinateSpanMake(mapView.region.span.latitudeDelta/2.0,
                         mapView.region.span.longitudeDelta/2.0);
    
    [mapView setRegion:MKCoordinateRegionMake(centerCoordinate, newSpan)
              animated:YES];
}

- (void)mapView:(MKMapView *)mapView annotationView:(MKAnnotationView *)view
calloutAccessoryControlTapped:(UIControl *)control
{
    MapLocation *annotationView = view.annotation;
    self.selectedLocation = annotationView.location;
    [self performSegueWithIdentifier:@"Location Detail Segue" sender:self];
}

- (NSPredicate *)setupFilterPredicate
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL free = [defaults boolForKey:@"free"];
    BOOL fee = [defaults boolForKey:@"fee"];
    
    NSMutableArray *predicates = [[NSMutableArray alloc] initWithCapacity:2];
    NSPredicate *predicate = [[NSPredicate alloc] init];
    
    if (free && !fee) {
        predicate = [NSPredicate predicateWithFormat:@"fee_type == 'Free'"];
        [predicates addObject:predicate];
    } else if (!free && fee) {
        predicate = [NSPredicate predicateWithFormat:@"fee_type == 'Fee-based'"];
        [predicates addObject:predicate];
    }
    
    if (predicates.count > 0) {
        return [NSCompoundPredicate andPredicateWithSubpredicates:predicates];
    }
    
    return nil;
}

- (void)reloadMap
{
    if (_fetchedResultsController)
	{
		// Execute the request
		NSError *error;
		BOOL success = [_fetchedResultsController performFetch:&error];
		if (!success)
			NSLog(@"No locations found");
		else
			[self plotMapLocations];
            [self setStandardRegion];
	}
}

- (void)importCoreDataDefaultLocations
{
    hud.labelText = @"Initializing location database...";
    hud.detailsLabelText = @"One time only. Please sit tight.";
    hud.mode = MBProgressHUDModeAnnularDeterminate;
    
    // Use SMXMLDocument to read location data in import XML file
    NSString *xmlPath = [[NSBundle mainBundle] pathForResource:@"import" ofType:@"xml"];
    NSData *xmlData = [NSData dataWithContentsOfFile:xmlPath];
    NSError *error;
    SMXMLDocument *document = [SMXMLDocument documentWithData:xmlData error:&error];
    
    // Prepare XML data and progress updates to be processed within asynchronous call
    __block SMXMLElement *mapLocations = [document.root childNamed:@"row"];
    __block float progress = 0.0f;
    __block float progressStep = 1.0f / [[document.root childNamed:@"row"] childrenNamed:@"row"].count;
    
    // Run asynchronous process to parse all XML data and insert into Core Data
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        // Set up a background MOC to use within this thread for storing data in the database
        _backgroundMOC = [[NSManagedObjectContext alloc] init];
        [_backgroundMOC setPersistentStoreCoordinator:[self.managedObjectContext persistentStoreCoordinator]];
        
        // Parse!
        for (SMXMLElement *mapLocation in [mapLocations childrenNamed:@"row"]) {
            LocationInfo *locationInfo = [NSEntityDescription insertNewObjectForEntityForName:@"LocationInfo"
                                                                       inManagedObjectContext:_backgroundMOC];
            
            //locationInfo.name = [mapLocation valueWithPath:@"name"];
            NSString *locationName = [mapLocation valueWithPath:@"name"];
            
            // Let's make sure all imported titles have the first letter uppercased so our list view's alphabetical index displays correctly later on
            locationInfo.name = [locationName stringByReplacingCharactersInRange:NSMakeRange(0,1)
                                              withString:[[locationName substringToIndex:1] capitalizedString]];
            locationInfo.address = [mapLocation valueWithPath:@"address"];
            
            // This data is a little old. McDonalds and Starbucks are still marked as 'fee-based', but they're free now, so let's 'free' them up.
            locationInfo.fee_type = [self setupLocationType:locationInfo.name:[mapLocation valueWithPath:@"type"]];
            
            LocationDetails *locationDetails = [NSEntityDescription
                                                insertNewObjectForEntityForName:@"LocationDetails"
                                                inManagedObjectContext:_backgroundMOC];
            
            SMXMLElement *shape = [mapLocation childNamed:@"shape"];
            locationDetails.latitude = [NSNumber numberWithDouble:[[shape attributeNamed:@"latitude"] doubleValue]];
            locationDetails.longitude = [NSNumber numberWithDouble:[[shape attributeNamed:@"longitude"] doubleValue]];
            locationDetails.city = [mapLocation valueWithPath:@"city"];
            locationDetails.zip = [NSNumber numberWithInteger:[[mapLocation valueWithPath:@"zip"] integerValue]];
            locationDetails.phone = [mapLocation valueWithPath:@"phone"];
            locationDetails.url = [mapLocation valueWithPath:@"url"];
            locationDetails.info = locationInfo;
            locationInfo.details = locationDetails;
            
            [_backgroundMOC save:nil];
            progress += progressStep;
            hud.progress = progress;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // Now that the asynchronous call is done, let's re-enable tab bar and nav bar buttons, and reload the map view with all our nifty new locations
            hud.detailsLabelText = nil;
            [self enableTabBarButtons];
            [self enableNavigationBarButtonsAndSearchBar];
            [self reloadMap];
        });
    });
}

- (NSString *)setupLocationType:(NSString *)locationName :(NSString *)locationType
{
    if ([locationName isEqualToString:@"Starbucks"] ||
        [locationName isEqualToString:@"McDonalds"] ||
        [locationName isEqualToString:@"McDonald's"]) {
        return @"Free";
    } else {
        return locationType;
    }
}

// Center map on Manhattan and set the zoom to cover the majority of the island (show a little bit of Brooklyn too)
- (void)setStandardRegion
{
    CLLocationCoordinate2D zoomLocation;
    zoomLocation.latitude = kCenterPointLatitude;
    zoomLocation.longitude = kCenterPointLongitude;
    
    MKCoordinateRegion viewRegion = MKCoordinateRegionMakeWithDistance(zoomLocation, kSpanDeltaLatitude*METERS_PER_MILE, kSpanDeltaLongitude*METERS_PER_MILE);
    
    MKCoordinateRegion adjustedRegion = [_mapView regionThatFits:viewRegion];
    [_mapView setRegion:adjustedRegion animated:YES];
}

- (void)viewWillAppear:(BOOL)animated
{    
    _mapView.delegate = self;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:(BOOL)animated];    // Call the super class implementation.
    // Usually calling super class implementation is done before self class implementation, but it's up to your application.
    
    // Stop tracking the user's location when we switch to another view to save battery
    _mapView.showsUserLocation = NO;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    _searchBar.hidden = YES;
    
    // Create the search and locate buttons
    _searchBarButtonItem = [[UIBarButtonItem alloc]
                            initWithBarButtonSystemItem:UIBarButtonSystemItemSearch
                            target:self
                            action:@selector(searchLocations)];
    
    _locateMeButtonItem = [[UIBarButtonItem alloc]
                           initWithImage:[UIImage imageNamed:@"locate-me-arrow.png"]
                           style:UIBarButtonItemStyleBordered
                           target:self
                           action:@selector(showUserLocation)];
    
    // Setup the Locate Me and address search buttons in the nav bar
    self.navigationItem.rightBarButtonItems = @[_locateMeButtonItem, _searchBarButtonItem];
    
    NSError *error;
	if (![[self fetchedResultsController] performFetch:&error]) {
		// Update to handle the error appropriately.
		NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
		exit(-1);  // Fail
	}
    
    hud = [MBProgressHUD showHUDAddedTo:self.view animated:YES];
    
    // If we're running the app for the first time, let's import all our locations. If not, load the locations from Core Data
    if (![[self.fetchedResultsController fetchedObjects] count] > 0) {
        [self setStandardRegion];
        [self disableTabBarButtons];
        [self disableNavigationBarButtonsAndSearchBar];
        [self importCoreDataDefaultLocations];
    }
    else {
        [self plotMapLocations];
        [self setStandardRegion];
    }
    
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    self.locationManager.distanceFilter = kCLDistanceFilterNone;
    self.locationManager.desiredAccuracy = kCLLocationAccuracyBest;
    
    popoverClass = [WEPopoverController class];
}

- (void)viewDidUnload
{
    [self setMapView:nil];
    [self.popoverController dismissPopoverAnimated:NO];
	self.popoverController = nil;
    [self setSearchBar:nil];
    [self setPopoverButton:nil];
    [super viewDidUnload];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    return (interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown);
}

- (void)plotMapLocations
{
    // Clear any and all annotations from the map so we can re-plot free, fee-based, or all locations
    [_mapView removeAnnotations:[_mapView annotations]];
    
    // Get Wi-Fi locations (free, fee-based, or all depending on if a fetch request predicate is set)
    _fetchedLocations = [[NSArray alloc] initWithArray:self.fetchedResultsController.fetchedObjects];
    __block NSMutableArray *pins = [NSMutableArray array];
    
    // Setup the location load progress indicator
    hud.labelText = @"Loading locations...";
    hud.mode = MBProgressHUDModeAnnularDeterminate;
    hud.progress = 0.0f;
    __block float progress = 0.0;
    __block float progressStep = 1.0 / _fetchedLocations.count;
    
    // Create map annotations for each fetched location
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        for (LocationInfo *location in _fetchedLocations) {
            LocationDetails *locationDetails = location.details;
            
            CLLocationCoordinate2D coordinate;
            coordinate.latitude = locationDetails.latitude.doubleValue;
            coordinate.longitude = locationDetails.longitude.doubleValue;
            
            MapLocation *annotation = [[MapLocation alloc] initWithLocation:location coordinate:coordinate];
            [pins addObject:annotation];
            
            progress += progressStep;
            hud.progress = progress;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // Plot location annotations on the map and hide the progress indicator
            [_mapView addAnnotations:pins];
            [MBProgressHUD hideHUDForView:self.view animated:YES];
        });
    });
}

- (void)locationManager:(CLLocationManager *)manager didUpdateToLocation:(CLLocation *)newLocation fromLocation:(CLLocation *)oldLocation {
    [self zoomToUserLocation:newLocation];
    [self.locationManager stopUpdatingLocation];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    UIAlertView *locationUpdateFailed = [[UIAlertView alloc] initWithTitle:@"Location Unavailable" message:@"Please try again and ensure Location Services are enabled for NYC Wi-Fi." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [locationUpdateFailed show];
}

- (void)zoomToUserLocation:(CLLocation *)userLocation
{
    if (!userLocation)
        return;
    
    MKCoordinateRegion region;
    region.center = userLocation.coordinate;
    region.span = MKCoordinateSpanMake(0.01, 0.01);
    region = [_mapView regionThatFits:region];
    [_mapView setRegion:region animated:YES];
}

// Compose email for Tell-A-Friend function
- (void)mailComposeController:(MFMailComposeViewController*)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError*)error
{
    switch (result)
    {
        case MFMailComposeResultCancelled:
            break;
        case MFMailComposeResultSaved:
            break;
        case MFMailComposeResultSent:
            break;
        case MFMailComposeResultFailed:
            break;
        default:
            break;
    }
    [self.popoverController dismissPopoverAnimated:YES];
    self.popoverController = nil;
    [self dismissModalViewControllerAnimated:YES];
}

- (WEPopoverContainerViewProperties *)improvedContainerViewProperties {
	
	WEPopoverContainerViewProperties *props = [WEPopoverContainerViewProperties alloc];
	NSString *bgImageName = nil;
	CGFloat bgMargin = 0.0;
	CGFloat bgCapSize = 0.0;
	CGFloat contentMargin = 4.0;
	
	bgImageName = @"popoverBg.png";
	
	// These constants are determined by the popoverBg.png image file and are image dependent
	bgMargin = 13; // margin width of 13 pixels on all sides popoverBg.png (62 pixels wide - 36 pixel background) / 2 == 26 / 2 == 13
	bgCapSize = 31; // ImageSize/2  == 62 / 2 == 31 pixels
	
	props.leftBgMargin = bgMargin;
	props.rightBgMargin = bgMargin;
	props.topBgMargin = bgMargin;
	props.bottomBgMargin = bgMargin;
	props.leftBgCapSize = bgCapSize;
	props.topBgCapSize = bgCapSize;
	props.bgImageName = bgImageName;
	props.leftContentMargin = contentMargin;
	props.rightContentMargin = contentMargin - 1; // Need to shift one pixel for border to look correct
	props.topContentMargin = contentMargin;
	props.bottomContentMargin = contentMargin;
	
	props.arrowMargin = 4.0;
	
	props.upArrowImageName = @"popoverArrowUp.png";
	props.downArrowImageName = @"popoverArrowDown.png";
	props.leftArrowImageName = @"popoverArrowLeft.png";
	props.rightArrowImageName = @"popoverArrowRight.png";
	return props;
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    if ([segue.identifier isEqualToString:@"Location Detail Segue"])
	{
        LocationDetailTVC *locationDetailTVC = segue.destinationViewController;
        locationDetailTVC.selectedLocation = self.selectedLocation;
	} else if ([segue.identifier isEqualToString:@"About Segue"]) {
        AboutViewController *aboutViewController = segue.destinationViewController;
        aboutViewController.delegate = self;
    } else if ([segue.identifier isEqualToString:@"Settings Segue"]) {
        SettingsTVC *settingsTVC = segue.destinationViewController;
        settingsTVC.delegate = self;
    }
}

#pragma mark -
#pragma mark Actions

- (IBAction)showPopover:(UIBarButtonItem *)sender {
    if (_floatingController) {
        [_floatingController dismissAnimated:YES];
        _floatingController = nil;
    }
    
	if (!self.popoverController) {
		
		PopoverViewController *contentViewController = [[PopoverViewController alloc] initWithStyle:UITableViewStylePlain];
        contentViewController.delegate = self;
		self.popoverController = [[popoverClass alloc] initWithContentViewController:contentViewController];
		self.popoverController.delegate = self;
		self.popoverController.passthroughViews = [NSArray arrayWithObject:self.navigationController.navigationBar];
        
		[self.popoverController presentPopoverFromBarButtonItem:sender
									   permittedArrowDirections:(UIPopoverArrowDirectionUp|UIPopoverArrowDirectionDown)
													   animated:YES];
	} else {
		[self.popoverController dismissPopoverAnimated:YES];
		self.popoverController = nil;
	}
}

- (void)searchLocations {
    if (_floatingController) {
        [_floatingController dismissAnimated:YES];
        _floatingController = nil;
    }
    
    // Check for an internet connection, and if one exists, allow the user to search for an address
    Reachability *networkReachability = [Reachability reachabilityForInternetConnection];
    NetworkStatus networkStatus = [networkReachability currentReachabilityStatus];
    if (networkStatus == NotReachable) {
        UIAlertView *notReachable = [[UIAlertView alloc] initWithTitle:@"Internet Connection Required"
                                                                      message:@"Please connect your device to the Internet and try your search again."
                                                                     delegate:nil
                                                            cancelButtonTitle:@"OK"
                                                            otherButtonTitles:nil];
        [notReachable show];
    } else {
        if (_searchBar.hidden) {
            _searchBar.hidden = NO;
            [_searchBar becomeFirstResponder];
        } else {
            _searchBar.hidden = YES;
            [_searchBar resignFirstResponder];
        }
    }
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    // Hide the search bar and keyboard, and disable all visible buttons to prevent the user from disrupting the search
    _searchBar.hidden = YES;
    [self disableTabBarButtons];
    [self disableNavigationBarButtonsAndSearchBar];
    [_searchBar resignFirstResponder];
    NSString *address = searchBar.text;
    _searchBar.text = @"";
    address = [self addNewYorkSuffixIfNecessary:[address lowercaseString]];
    
    // Perform the address search
    [self geolocateAddressAndZoomOnMap:address];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar
{
    _searchBar.hidden = YES;
    [_searchBar resignFirstResponder];
    _searchBar.text = @"";
}

- (void)geolocateAddressAndZoomOnMap:(NSString *)address
{
    // Remove the annotation marking the previously searched address, if one exists
    if (_mapView.lastSearchedAnnotation != nil) {
        [_mapView removeAnnotation:_mapView.lastSearchedAnnotation];
        _mapView.lastSearchedAnnotation = nil;
    }
    
    // Find the coordinates of the address
    CLGeocoder *coder = [[CLGeocoder alloc] init];
    hud = [MBProgressHUD showHUDAddedTo:self.view animated:YES];
    hud.labelText = @"Searching for address...";
    [coder geocodeAddressString:address completionHandler:^(NSArray *placemarks, NSError *error){
        if (!error && [self aValidZipCodeIfNumericWithSearchText:address]) {
            if (placemarks.count == 1) {
                // Only one placemark is returned, so let's zoom in and plot it
                CLPlacemark *placemark = [placemarks objectAtIndex:0];
                CLLocationCoordinate2D coordinate = [self getCoordinateWithPlacemark:placemark];
                _mapView.lastSearchedAnnotation = [[SearchMapPin alloc] initWithAddress:[self getFormattedAddressWithPlacemark:placemark]
                                                                             coordinate:coordinate];
                [self zoomMapAndCenterAtLatitude:coordinate.latitude andLongitude:coordinate.longitude];
            } else if (placemarks.count > 1) {
                // Multiple placemarks returned, so let the user select one and then zoom in and plot it
                AddressSelectTVC *addressSelectTVC = [[AddressSelectTVC alloc] init];
                addressSelectTVC.delegate = self;
                addressSelectTVC.addresses = placemarks;
                
                _floatingController = [CQMFloatingController sharedFloatingController];
                [_floatingController setPortraitFrameSize:CGSizeMake(320 - 66, 460 - 190)];
                [_floatingController setFrameColor:[[UIColor alloc] initWithRed:78.0f/255.0f green:143.0f/255.0f blue:218.0f/255.0f alpha:1]];
                [_floatingController showInView:self.view
                     withContentViewController:addressSelectTVC
                                      animated:YES];
            } else {
                UIAlertView *errorFindingAddress = [[UIAlertView alloc] initWithTitle:@"Address not found"
                                                                              message:@"No map location could be found for the address or zip code you entered. Please enter another and try again"
                                                                             delegate:nil
                                                                    cancelButtonTitle:@"OK"
                                                                    otherButtonTitles:nil];
                [errorFindingAddress show];
            }
        } else {
            UIAlertView *errorFindingAddress = [[UIAlertView alloc] initWithTitle:@"Whoops"
                                                                          message:@"Either the address you entered was invalid or there was an internet hiccup. Please check your Internet connection, enter a valid address, and try again."
                                                                         delegate:nil
                                                                cancelButtonTitle:@"OK"
                                                                otherButtonTitles:nil];
            [errorFindingAddress show];
            NSLog(@"%@", error);
        }
        
        // Re-enable our buttons so the user can interact with the whole app again
        [self enableTabBarButtons];
        [self enableNavigationBarButtonsAndSearchBar];
        [MBProgressHUD hideHUDForView:self.view animated:YES];
    }];
}

- (NSString *)addNewYorkSuffixIfNecessary:(NSString *)address
{
    // If the user did not include a borough name, New York, NY, or NYC in the address string, add in a default 'New York, NY'
    if (![self searchTextIsNumeric:address]) {
        if ([address rangeOfString:@"new york"].location == NSNotFound &&
            [address rangeOfString:@"ny"].location == NSNotFound &&
            [address rangeOfString:@"nyc"].location == NSNotFound &&
            [address rangeOfString:@"brooklyn"].location == NSNotFound &&
            [address rangeOfString:@"queens"].location == NSNotFound &&
            [address rangeOfString:@"bronx"].location == NSNotFound &&
            [address rangeOfString:@"staten"].location == NSNotFound) {
            return [NSString stringWithFormat:@"%@, New York, NY", address];
        }
    }
    
    return address;
}

- (BOOL)aValidZipCodeIfNumericWithSearchText:(NSString *)searchText
{
    // If the search text is numeric, make sure it is a legitimate zip code
    if ([self searchTextIsNumeric:searchText]) {
        NSString *zipRegex = @"(^[0-9]{5}(-[0-9]{4})?$)";
        NSPredicate *zipCheck = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", zipRegex];
        return [zipCheck evaluateWithObject:searchText];
    }
    return YES;
}

- (BOOL)searchTextIsNumeric:(NSString *)searchText
{
    if ([[[NSNumberFormatter alloc] init] numberFromString:searchText])
        return YES;
    
    return NO;
}

- (void)disableNavigationBarButtonsAndSearchBar
{
    _popoverButton.enabled = NO;
    _searchBar.userInteractionEnabled = NO;
    _searchBarButtonItem.enabled = NO;
    _locateMeButtonItem.enabled = NO;
}

- (void)enableNavigationBarButtonsAndSearchBar
{
    _popoverButton.enabled = YES;
    _searchBar.userInteractionEnabled = YES;
    _searchBarButtonItem.enabled = YES;
    _locateMeButtonItem.enabled = YES;
}

- (void)disableTabBarButtons
{
    UITabBarItem *tabBarItem = [[[[self tabBarController] tabBar] items] objectAtIndex:0];
    [tabBarItem setEnabled:NO];
    tabBarItem = [[[[self tabBarController] tabBar] items] objectAtIndex:1];
    [tabBarItem setEnabled:NO];
}

- (void)enableTabBarButtons
{
    UITabBarItem *tabBarItem = [[[[self tabBarController] tabBar] items] objectAtIndex:0];
    [tabBarItem setEnabled:YES];
    tabBarItem = [[[[self tabBarController] tabBar] items] objectAtIndex:1];
    [tabBarItem setEnabled:YES];
}

- (void)zoomMapAndCenterAtLatitude:(double)latitude andLongitude:(double)longitude
{
    MKCoordinateRegion region;
    region.center.latitude = latitude;
    region.center.longitude = longitude;
    region.span = MKCoordinateSpanMake(0.008, 0.008);
    region = [_mapView regionThatFits:region];
    [_mapView setRegion:region animated:YES];
}

- (void)showUserLocation {
    if (_floatingController) {
        [_floatingController dismissAnimated:YES];
        _floatingController = nil;
    }
    
    _mapView.showsUserLocation = YES;
    [self.locationManager startUpdatingLocation];
}

#pragma mark -
#pragma mark WEPopoverControllerDelegate implementation

- (void)popoverControllerDidDismissPopover:(WEPopoverController *)thePopoverController {
	//Safe to release the popover here
	self.popoverController = nil;
}

- (BOOL)popoverControllerShouldDismissPopover:(WEPopoverController *)thePopoverController {
	//The popover is automatically dismissed if you click outside it, unless you return NO here
	return YES;
}

#pragma mark -
#pragma mark PopoverViewControllerDelegate implementation

- (void)theAboutButtonOnThePopoverViewControllerWasTapped:(PopoverViewController *)controller
{
    [self performSegueWithIdentifier:@"About Segue" sender:self];
}

- (void)theTellAFriendButtonOnThePopoverViewControllerWasTapped:(PopoverViewController *)controller
{
    if ([MFMailComposeViewController canSendMail]) {
        MFMailComposeViewController *mailViewController = [[MFMailComposeViewController alloc] init];
        mailViewController.mailComposeDelegate = self;
        [mailViewController setSubject:@"NYC Wi-Fi App"];
        [mailViewController setMessageBody:@"<p>Check out this handy new app to help you find Wi-Fi in New York City!</p><p><a href=\"http://www.nycwifiapp.com\">http://www.nycwifiapp.com/</a></p>" isHTML:YES];
      
        [self presentModalViewController:mailViewController animated:YES];
    } else {
        UIAlertView *mailFailAlert = [[UIAlertView alloc] initWithTitle:@"Failure"
                                                        message:@"Your device doesn't support the email composer app window"
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [mailFailAlert show];
    }
}

- (void)theSettingsButtonOnThePopoverViewControllerWasTapped:(PopoverViewController *)controller
{
    [self performSegueWithIdentifier:@"Settings Segue" sender:self];
}

#pragma mark -
#pragma mark PopoverViewControllerDelegate implementation

- (void)theDoneButtonOnTheAboutViewControllerWasTapped:(AboutViewController *)controller
{
    [self.popoverController dismissPopoverAnimated:YES];
    self.popoverController = nil;
}

- (void)theDoneButtonOnTheSettingsTVCWasTapped:(SettingsTVC *)controller
{
    [self.popoverController dismissPopoverAnimated:YES];
    self.popoverController = nil;
    [_fetchedResultsController.fetchRequest setPredicate:[self setupFilterPredicate]];
    [self reloadMap];
}

#pragma mark -
#pragma mark AddressSelectTVCDelegate implementation

- (void)theSelectButtonOnTheAddressSelectTVCWasTapped:(AddressSelectTVC *)controller withAddress:(CLPlacemark *)placemark
{
    [_floatingController dismissAnimated:YES];
    _floatingController = nil;
    CLLocationCoordinate2D coordinate = [self getCoordinateWithPlacemark:placemark];
    _mapView.lastSearchedAnnotation = [[SearchMapPin alloc] initWithAddress:[self getFormattedAddressWithPlacemark:placemark]
                                                                 coordinate:coordinate];
    [self zoomMapAndCenterAtLatitude:coordinate.latitude andLongitude:coordinate.longitude];
}

- (NSString *)getFormattedAddressWithPlacemark:(CLPlacemark *)placemark
{
    if (!placemark.subThoroughfare) {
        if (placemark.postalCode)
            return [NSString stringWithFormat:@"%@", placemark.postalCode];
        else
            return @"Invalid Address";
    }
    
    return [NSString stringWithFormat:@"%@ %@, %@ %@", placemark.subThoroughfare, placemark.thoroughfare, placemark.locality, placemark.postalCode];
}

- (CLLocationCoordinate2D)getCoordinateWithPlacemark:(CLPlacemark *)placemark
{
    CLLocationCoordinate2D coordinate;
    coordinate.latitude = placemark.region.center.latitude;
    coordinate.longitude = placemark.region.center.longitude;
    return coordinate;
}

#pragma mark - fetchedResultsController

- (NSFetchedResultsController *)fetchedResultsController {
    
    if (_fetchedResultsController != nil) {
        return _fetchedResultsController;
    }
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    NSEntityDescription *entity = [NSEntityDescription
                                   entityForName:@"LocationInfo" inManagedObjectContext:_managedObjectContext];
    [fetchRequest setEntity:entity];
    [fetchRequest setPredicate:[self setupFilterPredicate]];
    
    NSSortDescriptor *sort = [[NSSortDescriptor alloc] initWithKey:@"name" ascending:YES];
    [fetchRequest setSortDescriptors:[NSArray arrayWithObject:sort]];
    
    NSFetchedResultsController *theFetchedResultsController =
    [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest
                                        managedObjectContext:_managedObjectContext sectionNameKeyPath:nil
                                                   cacheName:nil];
                                                   //cacheName:@"Root"];
    self.fetchedResultsController = theFetchedResultsController;
    _fetchedResultsController.delegate = self;
    
    return _fetchedResultsController;
    
}

- (void)controller:(NSFetchedResultsController *)controller didChangeObject:(id)anObject atIndexPath:(NSIndexPath *)indexPath forChangeType:(NSFetchedResultsChangeType)type newIndexPath:(NSIndexPath *)newIndexPath {
    
    switch(type) {
            
        case NSFetchedResultsChangeInsert:
            [self fetchedResultsChangeInsert:anObject];
            break;
            
        case NSFetchedResultsChangeDelete:
            [self fetchedResultsChangeDelete:anObject];
            break;
            
        case NSFetchedResultsChangeUpdate:
            [self fetchedResultsChangeUpdate:anObject];
            break;
            
        case NSFetchedResultsChangeMove:
            // Do nothing
            break;
    }
}

- (void)fetchedResultsChangeInsert:(NSObject*)anObject {
    LocationInfo *location = (LocationInfo*)anObject;
    LocationDetails *locationDetails = location.details;
    
    CLLocationCoordinate2D coordinate;
    coordinate.latitude = locationDetails.latitude.doubleValue;
    coordinate.longitude = locationDetails.longitude.doubleValue;
    
    MapLocation *annotation = [[MapLocation alloc] initWithLocation:location coordinate:coordinate];
    [_mapView addAnnotation:annotation];
}

- (void)fetchedResultsChangeDelete:(NSObject*)anObject  {
    LocationInfo *location = (LocationInfo*)anObject;
    LocationDetails *locationDetails = location.details;
    
    CLLocationCoordinate2D coordinate;
    coordinate.latitude = locationDetails.latitude.doubleValue;
    coordinate.longitude = locationDetails.longitude.doubleValue;
    
    //In case we have more then one match for whatever reason
    NSMutableArray *toRemove = [NSMutableArray arrayWithCapacity:1];
    for (id annotation in _mapView.annotations) {
        
        if (annotation != _mapView.userLocation) {
            MapLocation *pinAnnotation = annotation;
            
            // THIS NEEDS TO BE CHANGED TO OBJECTID IN THE NEXT VERSION FOR LOCATION MANAGEMENT
            if ([[pinAnnotation address] isEqualToString:location.address]) {
                [toRemove addObject:annotation];
            }
        }
    }
    [_mapView removeAnnotations:toRemove];
}

- (void)fetchedResultsChangeUpdate:(NSObject*)anObject  {
    //Takes a little bit of overheard but it is simple
    [self fetchedResultsChangeDelete:anObject];
    [self fetchedResultsChangeInsert:anObject];
    
}

@end
