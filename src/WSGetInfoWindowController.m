/*
 * WSGetInfoWindowController.m — the inspector: six sections, three of which write.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE WINDOW IS BUILT FROM THE ERA'S CONTROLS RATHER THAN FROM A NIB.** There is no nib compiler in this tree, and
 * every other window here is built the same way; the layout is arithmetic over a flipped container, which is why it
 * scrolls sensibly and why folding a section is a frame change rather than a second window.
 *
 * **THE SECTIONS ARE THE REFERENCE FILE MANAGER'S, AND EACH ONE IS A BAND WITH A TRIANGLE.** The band draws its own
 * grey and its own triangle: `NSOutlineView`'s disclosure triangle is a row affordance and not a view, so a section
 * header that folded itself has to be a view that folds itself. `WSInfoSectionView` is that view and nothing else —
 * it owns a title, a body and a collapsed bit.
 */
#import "WSGetInfoWindowController.h"

#import "WSFileOperations.h"
#import "WSItemIcons.h"
#import "WSItemInfo.h"
#import "WSMetadataStore.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSButton.h>
#import <AppKit/NSButtonCell.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphics.h>
#import <AppKit/NSImageView.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTableColumn.h>
#import <AppKit/NSTextContainer.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSTextFieldCell.h>
#import <AppKit/NSTextView.h>
#import <AppKit/NSView.h>
#import <AppKit/NSStringDrawing.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSBundle.h>
#import <Foundation/NSByteCountFormatter.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSNotification.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSString.h>

#include <sys/stat.h>

static const CGFloat WSInfoWindowWidth = 420.0;
static const CGFloat WSInfoWindowMaxHeight = 660.0;
static const CGFloat WSInfoHeaderHeight = 58.0;
static const CGFloat WSInfoSectionHeight = 22.0;
static const CGFloat WSInfoMargin = 12.0;
static const CGFloat WSInfoKeyWidth = 74.0;	/* the right-aligned "Kind:" column, so the values line up */
static const CGFloat WSInfoRowHeight = 17.0;
static const CGFloat WSInfoPreviewSize = 128.0;

/* **A VIEW THAT LAYS OUT FROM ITS TOP-LEFT CORNER**, which is what a stack of rows wants and what Cocoa's unflipped
 * default makes awkward: every frame here is measured downward from the top, the way the window reads. */
@interface WSInfoFlippedView : NSView
@end

@implementation WSInfoFlippedView
- (BOOL)isFlipped
{
	return YES;
}
@end

/* A LABEL: uneditable, unbezeled, no background — the era has no `+labelWithString:`, and a field that drew its own
 * white surface would read as something a person could type into. */
static NSTextField *WSInfoLabel(NSString *text, CGFloat x, CGFloat y, CGFloat width, CGFloat height, CGFloat size)
{
	NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(x, y, width, height)];

	[field setStringValue:(text != nil) ? text : @""];
	[field setEditable:NO];
	[field setSelectable:NO];
	[field setBezeled:NO];
	[field setBordered:NO];
	[field setDrawsBackground:NO];
	[field setFont:[NSFont systemFontOfSize:size]];
	return [field autorelease];
}

/* A VALUE THAT MAY BE ABSENT. A mixed selection and a file system without an attribute both answer nil, and both read
 * as an em dash rather than as an empty cell that looks like a bug. */
static NSString *WSInfoValue(NSString *value)
{
	return ([value length] > 0) ? value : @"—";
}

#pragma mark - The section

@interface WSInfoSectionView : NSView
{
	NSString *_title;		/* COPIED */
	NSView *_body;			/* RETAINED by the view hierarchy and by this class */
	BOOL _collapsed;
	id _target;			/* NOT RETAINED: the window controller owns the section */
	SEL _action;
}
- (instancetype)initWithTitle:(NSString *)title body:(NSView *)body target:(id)target action:(SEL)action;
- (CGFloat)cg_heightForWidth:(CGFloat)width;
- (void)cg_setWidth:(CGFloat)width;
- (BOOL)isCollapsed;
- (void)cg_setCollapsed:(BOOL)collapsed;
@end

@implementation WSInfoSectionView

- (instancetype)initWithTitle:(NSString *)title body:(NSView *)body target:(id)target action:(SEL)action
{
	self = [super initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, WSInfoSectionHeight)];
	if (self == nil) {
		return nil;
	}
	_title = [title copy];
	_body = [body retain];
	_target = target;
	_action = action;
	[self addSubview:_body];
	return self;
}

- (void)dealloc
{
	[_title release];
	[_body release];
	[super dealloc];
}

- (BOOL)isFlipped
{
	return YES;
}

- (BOOL)isCollapsed
{
	return _collapsed;
}

- (void)cg_setCollapsed:(BOOL)collapsed
{
	_collapsed = collapsed;
	[_body setHidden:collapsed];
	[self setNeedsDisplay:YES];
}

/* THE BAND, THE TRIANGLE AND THE TITLE, IN THAT ORDER: a filled band from the top of the view, a hairline under it, a
 * triangle that points where the section will go, and the title beside it. */
- (void)drawRect:(NSRect)dirtyRect
{
	NSRect bounds = [self bounds];
	NSRect band = NSMakeRect(0.0, 0.0, bounds.size.width, WSInfoSectionHeight);
	CGFloat midY = WSInfoSectionHeight / 2.0;
	NSBezierPath *triangle = [NSBezierPath bezierPath];
	NSDictionary *attributes;
	NSSize titleSize;

	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.91 alpha:1.0] set];
	NSRectFill(band);
	[[NSColor colorWithCalibratedWhite:0.74 alpha:1.0] set];
	NSRectFill(NSMakeRect(0.0, WSInfoSectionHeight - 1.0, bounds.size.width, 1.0));
	if (!_collapsed) {
		[[NSColor whiteColor] set];
		NSRectFill(NSMakeRect(0.0, WSInfoSectionHeight, bounds.size.width,
				      bounds.size.height - WSInfoSectionHeight));
	}

	if (_collapsed) {
		[triangle moveToPoint:NSMakePoint(9.0, midY - 4.0)];
		[triangle lineToPoint:NSMakePoint(16.0, midY + 0.5)];
		[triangle lineToPoint:NSMakePoint(9.0, midY + 5.0)];
	} else {
		[triangle moveToPoint:NSMakePoint(8.0, midY - 2.0)];
		[triangle lineToPoint:NSMakePoint(17.0, midY - 2.0)];
		[triangle lineToPoint:NSMakePoint(12.5, midY + 3.0)];
	}
	[triangle closePath];
	[[NSColor colorWithCalibratedWhite:0.33 alpha:1.0] set];
	[triangle fill];

	attributes = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSFont boldSystemFontOfSize:11.0], NSFontAttributeName,
		[NSColor colorWithCalibratedWhite:0.2 alpha:1.0], NSForegroundColorAttributeName,
		nil];
	titleSize = [(NSString *)WSInfoValue(_title) sizeWithAttributes:attributes];
	[WSInfoValue(_title) drawAtPoint:NSMakePoint(24.0, midY - titleSize.height / 2.0) withAttributes:attributes];
}

- (void)mouseDown:(NSEvent *)event
{
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];

	(void)event;
	if (point.y > WSInfoSectionHeight) {
		return;			/* a click in the body belongs to the body */
	}
	[self cg_setCollapsed:!_collapsed];
	if (_target != nil && _action != NULL) {
		[_target performSelector:_action withObject:self];
	}
}

- (CGFloat)cg_heightForWidth:(CGFloat)width
{
	CGFloat bodyHeight = _collapsed ? 0.0 : ([_body frame].size.height + 6.0);

	(void)width;
	return WSInfoSectionHeight + bodyHeight;
}

- (void)cg_setWidth:(CGFloat)width
{
	NSRect bodyFrame = [_body frame];

	[self setFrame:NSMakeRect([self frame].origin.x, [self frame].origin.y,
				  width, [self cg_heightForWidth:width])];
	[_body setFrame:NSMakeRect(WSInfoMargin, WSInfoSectionHeight + 6.0,
				   width - 2.0 * WSInfoMargin, bodyFrame.size.height)];
}

@end

#pragma mark - The container

@interface WSInfoDocumentView : NSView
{
	NSArray *_sections;		/* RETAINED */
	NSView *_header;		/* RETAINED by the hierarchy */
}
- (void)cg_setHeaderView:(NSView *)header;
- (void)cg_setSections:(NSArray *)sections;
- (BOOL)isFlipped;
- (CGFloat)cg_layoutWidth:(CGFloat)width;
@end

@implementation WSInfoDocumentView

- (void)cg_setHeaderView:(NSView *)header
{
	if (_header != header) {
		[_header removeFromSuperview];
		_header = header;
		if (_header != nil) {
			[self addSubview:_header];
		}
	}
}

- (void)cg_setSections:(NSArray *)sections
{
	if (_sections != sections) {
		NSUInteger i;

		for (i = 0; i < [_sections count]; i++) {
			[[_sections objectAtIndex:i] removeFromSuperview];
		}
		[_sections release];
		_sections = [sections retain];
		for (i = 0; i < [_sections count]; i++) {
			[self addSubview:[_sections objectAtIndex:i]];
		}
	}
}

- (void)dealloc
{
	[_sections release];
	[super dealloc];
}

- (BOOL)isFlipped
{
	return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor windowBackgroundColor] set];
	NSRectFill([self bounds]);
}

/* TOP-DOWN, ONE AFTER ANOTHER: the header band, then each section at whatever height its fold makes it. The total is
 * the document's height, which is what the scroll view scrolls. */
- (CGFloat)cg_layoutWidth:(CGFloat)width
{
	CGFloat y = 0.0;
	NSUInteger i;

	if (_header != nil) {
		[_header setFrame:NSMakeRect(0.0, y, width, WSInfoHeaderHeight)];
		y += WSInfoHeaderHeight;
	}
	for (i = 0; i < [_sections count]; i++) {
		WSInfoSectionView *section = [_sections objectAtIndex:i];
		CGFloat height;

		[section cg_setWidth:width];
		height = [section frame].size.height;
		[section setFrame:NSMakeRect(0.0, y, width, height)];
		y += height;
	}
	[self setFrame:NSMakeRect(0.0, 0.0, width, y)];
	return y;
}

@end

#pragma mark - The window

static NSMutableArray *s_infoWindows;		/* RETAINED: the open inspectors, oldest first */

@implementation WSGetInfoWindowController

+ (NSArray *)cg_openInfoWindows
{
	return (s_infoWindows != nil) ? s_infoWindows : [NSArray array];
}

+ (instancetype)infoWindowForPaths:(NSArray *)paths
{
	NSUInteger i;
	WSGetInfoWindowController *window;

	if ([paths count] == 0) {
		return nil;
	}
	if (s_infoWindows == nil) {
		s_infoWindows = [[NSMutableArray alloc] init];
	}
	for (i = 0; i < [s_infoWindows count]; i++) {
		window = [s_infoWindows objectAtIndex:i];
		if ([window cg_isShowingPaths:paths]) {
			[window reload];
			[window orderFront];
			return window;
		}
	}
	window = [[[self alloc] initWithPaths:paths] autorelease];
	[s_infoWindows addObject:window];
	[window orderFront];
	return window;
}

- (instancetype)initWithPaths:(NSArray *)paths
{
	WSItemInfo *info = [WSItemInfo infoForPaths:paths];
	NSWindow *window;
	NSScrollView *scroll;
	WSInfoDocumentView *document;
	NSMutableArray *sections;
	CGFloat contentHeight;

	if (info == nil) {
		[self release];
		return nil;
	}

	window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, WSInfoWindowMaxHeight)
					     styleMask:NSTitledWindowMask | NSClosableWindowMask
					       backing:NSBackingStoreBuffered
						 defer:NO];
	self = [super initWithWindow:window];
	[window release];
	if (self == nil) {
		return nil;
	}

	_info = [info retain];
	/* **THE COMMENT LIVES IN THE ENCLOSING FOLDER'S SIDECAR**, which is where this tier already keeps what a person
	 * decided about a name; a multiple selection has no one folder to ask and no one comment to show. */
	if (![info isMultiple]) {
		NSString *path = [[info paths] objectAtIndex:0];

		_store = [[WSMetadataStore storeForDirectory:[path stringByDeletingLastPathComponent]] retain];
		_commentsName = [[path lastPathComponent] copy];
	}

	[window setTitle:[self cg_windowTitle]];
	[window setDelegate:self];

	scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, WSInfoWindowMaxHeight)];
	[scroll setHasVerticalScroller:YES];
	[scroll setAutohidesScrollers:YES];
	[scroll setBorderType:NSNoBorder];
	[scroll setDrawsBackground:YES];
	document = [[WSInfoDocumentView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, WSInfoWindowMaxHeight)];
	[scroll setDocumentView:document];
	[document release];
	_documentView = document;

	[self cg_buildHeaderInDocument:document];
	sections = [[NSMutableArray alloc] init];
	[sections addObject:[self cg_generalSection]];
	[sections addObject:[self cg_moreInfoSection]];
	[sections addObject:[self cg_nameSection]];
	[sections addObject:[self cg_commentsSection]];
	[sections addObject:[self cg_previewSection]];
	[sections addObject:[self cg_sharingSection]];
	_sections = [sections copy];
	[sections release];
	[document cg_setSections:_sections];

	contentHeight = [document cg_layoutWidth:WSInfoWindowWidth];
	[window setContentView:scroll];
	[scroll release];
	{
		NSRect frame = [window frame];

		if (contentHeight + 4.0 < frame.size.height) {
			[window setContentSize:NSMakeSize(WSInfoWindowWidth, contentHeight + 4.0)];
		}
	}

	[self cg_updateFields];
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_info release];
	[_store release];
	[_commentsName release];
	[_documentView release];
	[_sections release];
	[super dealloc];
}

- (WSItemInfo *)info
{
	return _info;
}

- (NSArray *)paths
{
	return [_info paths];
}

- (BOOL)cg_isShowingPaths:(NSArray *)paths
{
	return [paths isEqualToArray:[_info paths]];
}

- (NSString *)cg_windowTitle
{
	if ([_info isMultiple]) {
		return [NSString stringWithFormat:@"%lu items Info", (unsigned long)[_info count]];
	}
	return WSInfoValue([_info name]);
}

#pragma mark - Building the sections

- (void)cg_buildHeaderInDocument:(WSInfoDocumentView *)document
{
	WSInfoFlippedView *band = [[WSInfoFlippedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth,
										      WSInfoHeaderHeight)];
	NSImage *icon = [self cg_iconWithSize:32];
	NSView *header = band;

	_headerIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(WSInfoMargin, 13.0, 32.0, 32.0)];
	if (icon != nil) {
		[_headerIcon setImage:icon];
	}
	[band addSubview:_headerIcon];
	[_headerIcon release];

	_headerName = [WSInfoLabel(nil, 52.0, 12.0, WSInfoWindowWidth - 52.0 - 84.0, 18.0, 13.0) retain];
	[_headerName setFont:[NSFont boldSystemFontOfSize:13.0]];
	[band addSubview:_headerName];
	[_headerName release];

	_headerDetail = [WSInfoLabel(nil, 52.0, 31.0, WSInfoWindowWidth - 52.0 - 84.0, 15.0, 10.0) retain];
	[_headerDetail setTextColor:[NSColor darkGrayColor]];
	[band addSubview:_headerDetail];
	[_headerDetail release];

	_headerSize = [WSInfoLabel(nil, WSInfoWindowWidth - 84.0 - WSInfoMargin, 12.0, 84.0, 18.0, 12.0) retain];
	[_headerSize setAlignment:NSRightTextAlignment];
	[band addSubview:_headerSize];
	[_headerSize release];

	[document cg_setHeaderView:header];
	[band release];
}

/* ONE ROW OF A SECTION: a right-aligned key and its value. Both are labels; the pair is what makes the column of
 * values line up without a grid. */
- (void)cg_addRowTo:(NSView *)body key:(NSString *)key value:(NSTextField **)valueSlot y:(CGFloat)y
{
	NSTextField *keyLabel;
	NSTextField *valueLabel;
	CGFloat width = [body frame].size.width;

	keyLabel = WSInfoLabel(key, 0.0, y, WSInfoKeyWidth, WSInfoRowHeight, 11.0);
	[keyLabel setAlignment:NSRightTextAlignment];
	[body addSubview:keyLabel];
	valueLabel = WSInfoLabel(nil, WSInfoKeyWidth + 8.0, y, width - WSInfoKeyWidth - 8.0, WSInfoRowHeight, 11.0);
	[body addSubview:valueLabel];
	if (valueSlot != NULL) {
		*valueSlot = valueLabel;
	}
}

- (WSInfoSectionView *)cg_generalSection
{
	WSInfoFlippedView *body = [[WSInfoFlippedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, 133.0)];
	WSInfoSectionView *section;
	CGFloat y = 0.0;

	[self cg_addRowTo:body key:@"Kind:" value:&_kindValue y:y]; y += WSInfoRowHeight;
	[self cg_addRowTo:body key:@"Size:" value:&_sizeValue y:y]; y += WSInfoRowHeight;
	[self cg_addRowTo:body key:@"Where:" value:&_whereValue y:y]; y += WSInfoRowHeight;
	[self cg_addRowTo:body key:@"Created:" value:&_createdValue y:y]; y += WSInfoRowHeight;
	[self cg_addRowTo:body key:@"Modified:" value:&_modifiedValue y:y]; y += WSInfoRowHeight + 6.0;

	/* **THE TWO BOXES ARE CHECKBOXES RATHER THAN SWITCHES**: the era's switch is a track with a knob, and the reference
	 * file manager's own inspector draws these two as the boxes beside every other checkbox in the system. */
	_sharedButton = [[NSButton alloc] initWithFrame:NSMakeRect(WSInfoKeyWidth, y, [body frame].size.width - WSInfoKeyWidth,
								  18.0)];
	[_sharedButton setButtonType:NSSwitchButton];
	[_sharedButton setTitle:@"Shared folder"];
	[_sharedButton setFont:[NSFont systemFontOfSize:11.0]];
	/* **SHARING IS NOT THIS TIER'S YET**, so the box is drawn and disabled: a folder can be shared over W12's network
	 * shares, and a tick here that nothing honoured would be a setting that lies. */
	[_sharedButton setEnabled:NO];
	[body addSubview:_sharedButton];
	[_sharedButton release];
	y += 20.0;

	_lockedButton = [[NSButton alloc] initWithFrame:NSMakeRect(WSInfoKeyWidth, y, [body frame].size.width - WSInfoKeyWidth,
								  18.0)];
	[_lockedButton setButtonType:NSSwitchButton];
	[_lockedButton setTitle:@"Locked"];
	[_lockedButton setFont:[NSFont systemFontOfSize:11.0]];
	[_lockedButton setAllowsMixedState:YES];
	[_lockedButton setTarget:self];
	[_lockedButton setAction:@selector(lockedChanged:)];
	[body addSubview:_lockedButton];
	[_lockedButton release];

	section = [[WSInfoSectionView alloc] initWithTitle:@"General" body:body target:self
						   action:@selector(cg_sectionToggled:)];
	[body release];
	return [section autorelease];
}

- (WSInfoSectionView *)cg_moreInfoSection
{
	WSInfoFlippedView *body = [[WSInfoFlippedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, 23.0)];
	WSInfoSectionView *section;

	[self cg_addRowTo:body key:@"Last opened:" value:&_lastOpenedValue y:0.0];
	section = [[WSInfoSectionView alloc] initWithTitle:@"More Info" body:body target:self
						   action:@selector(cg_sectionToggled:)];
	[body release];
	return [section autorelease];
}

- (WSInfoSectionView *)cg_nameSection
{
	WSInfoFlippedView *body = [[WSInfoFlippedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, 30.0)];
	WSInfoSectionView *section;
	NSTextField *field;

	field = [[NSTextField alloc] initWithFrame:NSMakeRect(0.0, 2.0, [body frame].size.width, 26.0)];
	[field setFont:[NSFont systemFontOfSize:11.0]];
	[field setTarget:self];
	[field setAction:@selector(nameFieldAction:)];
	[body addSubview:field];
	_nameField = [field retain];
	[field release];

	section = [[WSInfoSectionView alloc] initWithTitle:@"Name & Extension" body:body target:self
						   action:@selector(cg_sectionToggled:)];
	[body release];
	return [section autorelease];
}

- (WSInfoSectionView *)cg_commentsSection
{
	WSInfoFlippedView *body = [[WSInfoFlippedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, 78.0)];
	WSInfoSectionView *section;
	NSScrollView *scroll;
	NSTextView *text;

	scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 2.0, [body frame].size.width, 74.0)];
	[scroll setHasVerticalScroller:YES];
	[scroll setAutohidesScrollers:YES];
	[scroll setBorderType:NSBezelBorder];
	[scroll setDrawsBackground:YES];
	text = [[NSTextView alloc] initWithFrame:[[scroll contentView] bounds] textContainer:nil];
	[text setRichText:NO];
	[text setFont:[NSFont systemFontOfSize:11.0]];
	[text setVerticallyResizable:YES];
	[text setHorizontallyResizable:NO];
	[[text textContainer] setWidthTracksTextView:YES];
	[scroll setDocumentView:text];
	[body addSubview:scroll];
	_commentsView = [text retain];
	[text release];
	[scroll release];
	/* **THE COMMENT IS SAVED AS IT IS TYPED**, not when the window closes: a person who types a note and then closes
	 * the window with the title bar's button never sends the field an "end editing", and a comment that is lost that
	 * way is worse than a small plist write per keystroke. The view announces the edit through the notification
	 * centre — `NSTextDelegate`'s `-textDidChange:` is not sent by this tier's text view, and the header says so. */
	[[NSNotificationCenter defaultCenter] addObserver:self
						 selector:@selector(commentsChanged:)
						     name:NSTextDidChangeNotification
						   object:_commentsView];

	section = [[WSInfoSectionView alloc] initWithTitle:@"Comments" body:body target:self
						   action:@selector(cg_sectionToggled:)];
	[body release];
	return [section autorelease];
}

- (WSInfoSectionView *)cg_previewSection
{
	WSInfoFlippedView *body = [[WSInfoFlippedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, 138.0)];
	WSInfoSectionView *section;

	_previewView = [[NSImageView alloc] initWithFrame:NSMakeRect((WSInfoWindowWidth - 2.0 * WSInfoMargin - WSInfoPreviewSize) / 2.0,
								   6.0, WSInfoPreviewSize, WSInfoPreviewSize)];
	[_previewView setImageScaling:NSImageScaleProportionallyUpOrDown];
	[body addSubview:_previewView];
	[_previewView release];

	section = [[WSInfoSectionView alloc] initWithTitle:@"Preview" body:body target:self
						   action:@selector(cg_sectionToggled:)];
	[body release];
	return [section autorelease];
}

- (WSInfoSectionView *)cg_sharingSection
{
	WSInfoFlippedView *body = [[WSInfoFlippedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, 104.0)];
	WSInfoSectionView *section;
	NSTableColumn *name;
	NSTableColumn *privilege;
	NSTableView *table;
	CGFloat tableWidth = WSInfoWindowWidth - 2.0 * WSInfoMargin;

	_permissionSummary = [WSInfoLabel(nil, 0.0, 0.0, tableWidth, WSInfoRowHeight, 11.0) retain];
	[body addSubview:_permissionSummary];
	[_permissionSummary release];

	table = [[NSTableView alloc] initWithFrame:NSMakeRect(0.0, 21.0, tableWidth, 78.0)];
	tableWidth -= 4.0;
	name = [[NSTableColumn alloc] initWithIdentifier:@"Name"];
	[name setWidth:tableWidth * 0.55];
	[table addTableColumn:name];
	[name release];
	privilege = [[NSTableColumn alloc] initWithIdentifier:@"Privilege"];
	[privilege setWidth:tableWidth * 0.45];
	[table addTableColumn:privilege];
	[privilege release];
	[table setRowHeight:20.0];
	[table setAllowsEmptySelection:YES];
	[table setAllowsMultipleSelection:NO];
	[table setDataSource:self];
	[table setDelegate:self];
	[body addSubview:table];
	_permissionTable = [table retain];
	[table release];

	section = [[WSInfoSectionView alloc] initWithTitle:@"Sharing & Permissions" body:body target:self
						   action:@selector(cg_sectionToggled:)];
	[body release];
	return [section autorelease];
}

#pragma mark - Filling it in

- (NSImage *)cg_iconWithSize:(NSInteger)size
{
	NSString *path = [[_info paths] objectAtIndex:0];
	BOOL isDirectory = NO;

	(void)[[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];
	return [WSItemIcons thumbnailForPath:path size:size] != nil
		? [WSItemIcons thumbnailForPath:path size:size]
		: [WSItemIcons iconForPath:path isDirectory:isDirectory size:size];
}

- (void)cg_updateFields
{
	NSString *detail;
	NSString *sizeLine;
	NSArray *rows;

	[_headerName setStringValue:([_info isMultiple]
		? [NSString stringWithFormat:@"%lu items", (unsigned long)[_info count]]
		: WSInfoValue([_info name]))];
	detail = [NSString stringWithFormat:@"Modified: %@", [WSItemInfo dateDescription:[_info modificationDate]]];
	[_headerDetail setStringValue:[_info isMultiple] ? @"" : detail];
	[_headerSize setStringValue:[NSByteCountFormatter stringFromByteCount:(long long)[_info onDiskByteCount]
								  countStyle:NSByteCountFormatterCountStyleFile]];

	sizeLine = [WSItemInfo sizeDescriptionForBytes:[_info byteCount] onDisk:[_info onDiskByteCount]];
	if ([_info countsItems]) {
		sizeLine = [NSString stringWithFormat:@"%@ %@", sizeLine,
			[WSItemInfo itemCountDescription:[_info itemCount]]];
	}
	[_kindValue setStringValue:WSInfoValue([_info kind])];
	[_sizeValue setStringValue:sizeLine];
	[_whereValue setStringValue:WSInfoValue([_info where])];
	[_createdValue setStringValue:[WSItemInfo dateDescription:[_info creationDate]]];
	[_modifiedValue setStringValue:[WSItemInfo dateDescription:[_info modificationDate]]];
	[_lastOpenedValue setStringValue:[WSItemInfo dateDescription:[_info lastOpenedDate]]];
	[_lockedButton setState:[_info lockedState]];
	[_nameField setStringValue:([_info isMultiple] ? @"" : WSInfoValue([_info name]))];
	[_nameField setEditable:![_info isMultiple]];

	rows = [_info permissions];
	[rows retain];
	[_permissions release];
	_permissions = rows;
	[_permissionSummary setStringValue:[_info mixedPermissions] ? @"—" : [_info permissionSummary]];
	[_permissionTable reloadData];
	[_previewView setImage:[self cg_iconWithSize:(NSInteger)WSInfoPreviewSize]];

	/* THE COMMENT IS THE SIDECAR'S, and it is read only for the one item the window is about. */
	{
		NSString *comment = (nil != _store && _commentsName != nil)
			? [_store commentForName:_commentsName] : nil;

		[_commentsView setString:(comment != nil) ? comment : @""];
		[_commentsView setEditable:(_store != nil)];
	}
	[[self window] setTitle:[self cg_windowTitle]];
}

- (void)reload
{
	WSItemInfo *info = [WSItemInfo infoForPaths:[_info paths]];

	if (info == nil) {
		return;
	}
	[info retain];
	[_info release];
	_info = info;
	[self cg_updateFields];
	[self cg_layout];
}

- (void)cg_layout
{
	CGFloat height = [(WSInfoDocumentView *)_documentView cg_layoutWidth:WSInfoWindowWidth];

	(void)height;
	[[self window] displayIfNeeded];
}

- (void)orderFront
{
	[self reload];
	[[self window] center];
	[[self window] makeKeyAndOrderFront:nil];
}

#pragma mark - What the window writes

- (void)cg_sectionToggled:(id)sender
{
	(void)sender;
	[self cg_layout];
}

/* **THE NAME FIELD RENAMES THROUGH THE FILE OPERATIONS' OWN DOOR.** The validation ("no slash", "not . or ..") and the
 * "that name is taken" refusal are the same ones every other rename in this shell uses, so a name this field accepts is
 * a name the views accept. The operations object is private to this window and has no undo manager: the window outlives
 * the one that opened it, and an undo entry pointing at a dead window's manager would be worse than no undo entry. */
- (void)nameFieldAction:(id)sender
{
	NSString *typed = [[_nameField stringValue] stringByTrimmingCharactersInSet:
		[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSString *oldName = [_info name];
	NSString *path = [[_info paths] objectAtIndex:0];
	WSFileOperations *operations;
	NSError *error = nil;
	NSString *destination;

	(void)sender;
	if ([_info isMultiple] || [typed length] == 0 || [typed isEqual:oldName]) {
		[_nameField setStringValue:WSInfoValue(oldName)];
		return;
	}
	operations = [[WSFileOperations alloc] initWithUndoManager:nil trash:nil];
	destination = [operations renamePath:path toName:typed error:&error];
	[operations release];
	if (destination == nil) {
		/* A REFUSED NAME STAYS REFUSED AND THE FIELD GOES BACK: the window shows what is on the disk, so a person sees
		 * the rename did not happen rather than a field that keeps a name the file does not have. */
		[_nameField setStringValue:WSInfoValue(oldName)];
		return;
	}
	/* THE COMMENT MOVES WITH THE NAME, because it is filed under it. A comment left under the old key would appear to
	 * have been deleted by a rename. */
	if (_store != nil && _commentsName != nil) {
		NSString *comment = [_store commentForName:_commentsName];

		if (comment != nil) {
			[_store setComment:comment forName:[destination lastPathComponent]];
			[_store removeCommentForName:_commentsName];
			[_store save];
		}
		[_commentsName release];
		_commentsName = [[destination lastPathComponent] copy];
	}
	[self reload];
}

/* **LOCKED IS THE OWNER'S WRITE BIT, WHICH IS THE HONEST READING OF IT HERE.** This kernel has no chflags(2) user
 * immutable flag, so "locked" cannot mean what it means on the reference system; it can mean "the account that owns
 * this file may not change it", which is the effect a person wants and a mode bit that already exists. Ticking it
 * clears `S_IWUSR` on every selected item and unticking sets it, keeping every other bit. */
- (void)lockedChanged:(id)sender
{
	NSInteger state = [sender state];
	NSArray *paths = [_info paths];
	NSUInteger i;

	if (state == NSMixedState) {
		state = NSOnState;
	}
	for (i = 0; i < [paths count]; i++) {
		struct stat s;

		if (stat([[paths objectAtIndex:i] fileSystemRepresentation], &s) != 0) {
			continue;
		}
		(void)chmod([[paths objectAtIndex:i] fileSystemRepresentation],
			    (state == NSOnState) ? (s.st_mode & ~(mode_t)S_IWUSR) : (s.st_mode | (mode_t)S_IWUSR));
	}
	[self reload];
}

- (void)commentsChanged:(NSNotification *)notification
{
	NSString *text;

	(void)notification;
	if (_store == nil || _commentsName == nil) {
		return;
	}
	text = [[_commentsView textStorage] string];
	if ([text length] > 0) {
		[_store setComment:text forName:_commentsName];
	} else {
		[_store removeCommentForName:_commentsName];
	}
	[_store save];
}

#pragma mark - The permissions table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	(void)tableView;
	return (NSInteger)[_permissions count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	WSItemPermission *permission;
	id identifier;

	(void)tableView;
	if (row < 0 || (NSUInteger)row >= [_permissions count]) {
		return nil;
	}
	permission = [_permissions objectAtIndex:(NSUInteger)row];
	identifier = [tableColumn identifier];
	if ([identifier isEqual:@"Privilege"]) {
		return [_info mixedPermissions] ? @"—" : [permission privilege];
	}
	return [permission name];
}

#pragma mark - The window's own life

- (void)windowWillClose:(NSNotification *)notification
{
	(void)notification;
	/* THE REGISTRY'S RETAIN IS THE WINDOW'S OWNER, so leaving it releases the window — after `-retain`/`-autorelease`
	 * because this method is running inside the object that remove releases. */
	[[self retain] autorelease];
	if (s_infoWindows != nil) {
		[s_infoWindows removeObjectIdenticalTo:self];
	}
}

#pragma mark - The probe's doors

- (NSTextField *)cg_kindValue { return _kindValue; }
- (NSTextField *)cg_sizeValue { return _sizeValue; }
- (NSTextField *)cg_whereValue { return _whereValue; }
- (NSTextField *)cg_createdValue { return _createdValue; }
- (NSTextField *)cg_modifiedValue { return _modifiedValue; }
- (NSTextField *)cg_lastOpenedValue { return _lastOpenedValue; }
- (NSTextField *)cg_nameField { return _nameField; }
- (NSTextField *)cg_permissionSummary { return _permissionSummary; }
- (NSTableView *)cg_permissionTable { return _permissionTable; }
- (NSTextView *)cg_commentsView { return _commentsView; }
- (NSImageView *)cg_previewView { return _previewView; }
- (NSButton *)cg_lockedButton { return _lockedButton; }
- (NSUInteger)cg_sectionCount { return [_sections count]; }

@end
