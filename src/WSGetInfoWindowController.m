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
#import <AppKit/NSScreen.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSMenuItem.h>
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
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSThread.h>
#import <Foundation/NSString.h>

#include <sys/stat.h>

static const CGFloat WSInfoWindowWidth = 420.0;
static const CGFloat WSInfoWindowMaxHeight = 700.0;
static const CGFloat WSInfoHeaderHeight = 58.0;
static const CGFloat WSInfoSectionHeight = 22.0;
static const CGFloat WSInfoMargin = 12.0;
static const CGFloat WSInfoKeyWidth = 74.0;	/* the right-aligned "Kind:" column, so the values line up */
static const CGFloat WSInfoRowHeight = 17.0;
static const CGFloat WSInfoPreviewSize = 260.0;

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
	NSTextField *_titleLabel;	/* RETAINED by the view hierarchy */
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
	/* **THE TITLE IS A LABEL AND NOT A DRAWN STRING.** This view is flipped, and Core Text's line drawing takes the
	 * point as a BASELINE in an unflipped space — MEASURED, a title drawn at the band's middle landed under the band's
	 * bottom edge and was painted over by the next section's body. A field is laid out in its own frame and needs no
	 * such reasoning, and it is the same label every other title in this window is. */
	_titleLabel = [WSInfoLabel(title, 24.0, 3.0, 260.0, 16.0, 11.0) retain];
	[_titleLabel setFont:[NSFont boldSystemFontOfSize:11.0]];
	[self addSubview:_titleLabel];
	[self addSubview:_body];
	return self;
}

- (void)dealloc
{
	[_title release];
	[_titleLabel release];
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
	[_titleLabel setFrame:NSMakeRect(24.0, 3.0, width - 24.0 - WSInfoMargin, 16.0)];
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

#pragma mark - The permissions table

/* **A CLICK IN THE PRIVILEGE COLUMN IS THE POP-UP'S CLICK, NOT A ROW SELECTION.** `NSTableView -mouseDown:` selects and
 * tracks a drag; a pop-up cell only opens through `-performClickOnCellAtColumn:row:`, which this tier already has (it
 * is what the cell's own `-performClickWithFrame:inView:` is for). So the table answers that one column itself and hands
 * everything else to the table — and it remembers WHICH ROW it opened, because the cell that reports the pick is shared
 * by all three rows and the action arrives with the table as its sender. */
/* **THE MENU IS THE WINDOW'S, AND THIS IS THE QUESTION IT ASKS.** A table cannot know what a privilege is; it knows a
 * click landed in the Privilege column of a row, which is the whole of what the window needs to raise the four choices. */
@protocol WSInfoPermissionMenuTarget <NSObject>
- (void)permissionsTable:(NSTableView *)table showPrivilegeMenuForRow:(NSInteger)row atPoint:(NSPoint)point;
@end

@interface WSInfoPermissionTable : NSTableView
{
	NSInteger _cgPopupRow;
}
- (NSInteger)cg_popupRow;
- (void)cg_setPopupRow:(NSInteger)row;
@end

@implementation WSInfoPermissionTable

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_cgPopupRow = -1;
	}
	return self;
}

- (NSInteger)cg_popupRow
{
	return _cgPopupRow;
}

- (void)cg_setPopupRow:(NSInteger)row
{
	_cgPopupRow = row;
}

- (void)mouseDown:(NSEvent *)event
{
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSInteger row = [self rowAtPoint:point];
	NSInteger column = [self columnAtPoint:point];
	NSArray *columns = [self tableColumns];

	if (row >= 0 && column >= 0 && (NSUInteger)column < [columns count]
	    && [[[columns objectAtIndex:(NSUInteger)column] identifier] isEqual:@"Privilege"]
	    && [[self delegate] respondsToSelector:@selector(permissionsTable:showPrivilegeMenuForRow:atPoint:)]) {
		_cgPopupRow = row;
		[(id <WSInfoPermissionMenuTarget>)[self delegate] permissionsTable:self
							     showPrivilegeMenuForRow:row
									   atPoint:point];
		return;
	}
	[super mouseDown:event];
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
	/* **THE WINDOW OPENS WITH ONLY THE FIRST SECTION OPEN**, which is the shape the reference file manager's inspector
	 * has: General is what a person came to read, the other five are a fold away, and a window that showed all six at
	 * once would be taller than the desktop it sits on before it said anything. */
	{
		NSUInteger i;

		for (i = 1; i < [_sections count]; i++) {
			[[_sections objectAtIndex:i] cg_setCollapsed:YES];
		}
	}
	[document cg_setSections:_sections];

	contentHeight = [document cg_layoutWidth:WSInfoWindowWidth];
	[window setContentView:scroll];
	[scroll release];
	[self cg_fitWindowToHeight:contentHeight];

	[self cg_updateFields];
	[self cg_startSizeMeasure];
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
	[_generalBody release];
	[_previewBody release];
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
	[_headerIcon setImageScaling:NSImageScaleProportionallyUpOrDown];
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
 * values line up without a grid. **THE ROW IS BUILT, NOT PLACED** — its y is the caller's, because General re-stacks its
 * rows whenever a fact it has no answer for is left out. */
- (void)cg_addRowTo:(NSView *)body key:(NSString *)key keyOut:(NSTextField **)keySlot value:(NSTextField **)valueSlot
{
	NSTextField *keyLabel;
	NSTextField *valueLabel;
	CGFloat width = [body frame].size.width;

	keyLabel = WSInfoLabel(key, 0.0, 0.0, WSInfoKeyWidth, WSInfoRowHeight, 11.0);
	[keyLabel setAlignment:NSRightTextAlignment];
	[body addSubview:keyLabel];
	valueLabel = WSInfoLabel(nil, WSInfoKeyWidth + 8.0, 0.0, width - WSInfoKeyWidth - 8.0, WSInfoRowHeight, 11.0);
	[body addSubview:valueLabel];
	if (keySlot != NULL) {
		*keySlot = keyLabel;
	}
	if (valueSlot != NULL) {
		*valueSlot = valueLabel;
	}
}

- (WSInfoSectionView *)cg_generalSection
{
	WSInfoFlippedView *body = [[WSInfoFlippedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, 140.0)];
	WSInfoSectionView *section;
	CGFloat y = 0.0;

	[self cg_addRowTo:body key:@"Kind:" keyOut:&_kindKey value:&_kindValue];
	[self cg_addRowTo:body key:@"Size:" keyOut:&_sizeKey value:&_sizeValue];
	[self cg_addRowTo:body key:@"Where:" keyOut:&_whereKey value:&_whereValue];
	[self cg_addRowTo:body key:@"Created:" keyOut:&_createdKey value:&_createdValue];
	[self cg_addRowTo:body key:@"Modified:" keyOut:&_modifiedKey value:&_modifiedValue];

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
	_generalBody = [body retain];

	section = [[WSInfoSectionView alloc] initWithTitle:@"General" body:body target:self
						   action:@selector(cg_sectionToggled:)];
	[body release];
	return [section autorelease];
}

- (WSInfoSectionView *)cg_moreInfoSection
{
	WSInfoFlippedView *body = [[WSInfoFlippedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, 23.0)];
	WSInfoSectionView *section;

	[self cg_addRowTo:body key:@"Last opened:" keyOut:NULL value:&_lastOpenedValue];
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
	WSInfoFlippedView *body = [[WSInfoFlippedView alloc] initWithFrame:
		NSMakeRect(0.0, 0.0, WSInfoWindowWidth, WSInfoPreviewSize + 12.0)];
	WSInfoSectionView *section;

	/* **THE PANE IS AS TALL AS THE PICTURE, NOT AS TALL AS THE BOX.** A wide screenshot fitted into a square leaves two
	 * bands of white above and below it, which is what a preview pane full of nothing looks like; `-cg_updatePreview`
	 * measures the picture and gives this body its height, so the section hugs what is in it. */
	_previewBody = [body retain];
	_previewView = [[NSImageView alloc] initWithFrame:NSMakeRect(([body frame].size.width - WSInfoPreviewSize) / 2.0,
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
	WSInfoFlippedView *body = [[WSInfoFlippedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WSInfoWindowWidth, 118.0)];
	WSInfoSectionView *section;
	NSTableColumn *name;
	NSTableColumn *privilege;
	NSTableView *table;
	NSScrollView *tableScroll;
	CGFloat tableWidth = WSInfoWindowWidth - 2.0 * WSInfoMargin;

	_permissionSummary = [WSInfoLabel(nil, 0.0, 0.0, tableWidth, WSInfoRowHeight, 11.0) retain];
	[body addSubview:_permissionSummary];
	[_permissionSummary release];

	/* **A TABLE IS THE DOCUMENT VIEW OF A SCROLL VIEW, HERE AS EVERYWHERE ELSE IN THIS TIER.** A table added bare to a
	 * view whose window is already scrolling installs its header — and takes its own frame — from the OUTER scroll view,
	 * which MEASURED put the permissions table across the top of the window and its header over the window's own. The
	 * inner scroll view is the table's own enclosure, and it is the one the header belongs to. */
	tableScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 21.0, tableWidth, 90.0)];
	[tableScroll setHasVerticalScroller:NO];
	[tableScroll setHasHorizontalScroller:NO];
	[tableScroll setAutohidesScrollers:YES];
	[tableScroll setBorderType:NSBezelBorder];
	[tableScroll setDrawsBackground:YES];
	table = [[WSInfoPermissionTable alloc] initWithFrame:[[tableScroll contentView] bounds]];
	tableWidth -= 4.0;
	name = [[NSTableColumn alloc] initWithIdentifier:@"Name"];
	[name setWidth:tableWidth * 0.55];
	[table addTableColumn:name];
	[name release];
	privilege = [[NSTableColumn alloc] initWithIdentifier:@"Privilege"];
	[privilege setWidth:tableWidth * 0.45];
	/* **THE CELL STAYS A PLAIN FIELD AND THE CHOICE IS A MENU, NOT A POP-UP CELL.** `NSPopUpButtonCell` draws its title
	 * one line-height low inside a flipped table — MEASURED in a session: the words were cut in half by the row under
	 * them — so a click in this column raises the four choices as an ordinary menu at the pointer instead. The value is
	 * a string the field already draws correctly, and the menu is the same `-popUpMenuPositioningItem:atLocation:inView:`
	 * a pop-up cell would use. */
	[table addTableColumn:privilege];
	[privilege release];
	/* **THE HEADER AND THREE ROWS HAVE TO FIT THE TABLE.** 20-point rows under a 20-point header came to 80 in a
	 * 78-point scroll view, so the third row was cut in half by the table's own frame. */
	[table setRowHeight:22.0];
	[table setAllowsEmptySelection:YES];
	[table setAllowsMultipleSelection:NO];
	[table setDataSource:self];
	[table setDelegate:self];
	[tableScroll setDocumentView:table];
	[body addSubview:tableScroll];
	_permissionTable = [table retain];
	[table release];
	[tableScroll release];

	section = [[WSInfoSectionView alloc] initWithTitle:@"Sharing & Permissions" body:body target:self
						   action:@selector(cg_sectionToggled:)];
	[body release];
	return [section autorelease];
}

#pragma mark - Filling it in

/* **AN ICON IS ASKED FOR IN THE PIXELS THE SURFACE HAS, AND DRAWN IN POINTS.** `WSItemIcons` answers an image whose
 * size is its pixel size, so asking for 32 on a window at 1.332 draws a 32-pixel picture into 32 points — the compositor
 * then stretches it by a third, which is the softness a person sees and calls a bad preview. The scale is the window's
 * own (`-userSpaceScaleFactor`, the factor its bitmap context was made with), and the view scales the extra pixels back
 * down, which is a downscale and stays sharp. */
- (NSImage *)cg_iconWithSize:(NSInteger)size
{
	NSString *path = [[_info paths] objectAtIndex:0];
	BOOL isDirectory = NO;
	CGFloat scale = [[self window] userSpaceScaleFactor];
	NSInteger pixels;
	NSImage *image;

	if (scale <= 0.0) {
		scale = 1.0;
	}
	pixels = (NSInteger)((CGFloat)size * scale + 0.5);
	(void)[[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];
	image = [WSItemIcons thumbnailForPath:path size:pixels];
	if (image == nil) {
		image = [WSItemIcons iconForPath:path isDirectory:isDirectory size:pixels];
	}
	return image;
}

/* **THE PREVIEW IS THE PICTURE ITSELF, AT ITS OWN SHAPE AND THE SURFACE'S RESOLUTION.** Two things were wrong with a
 * square 128-point thumbnail in this pane: it was decoded at 128 pixels and stretched by the window's scale, and it
 * carried the transparent bands of a square around a wide picture, so the pane was mostly white. `-cg_pictureForPath:`
 * answers the picture with no bands, and the pane's body takes the picture's height, which is why the window grows to
 * fit a tall one and stays short for a wide one. A file this tier cannot decode keeps its icon, which is square. */
- (void)cg_updatePreview
{
	NSString *path = [[_info paths] objectAtIndex:0];
	BOOL isDirectory = NO;
	CGFloat scale = [[self window] userSpaceScaleFactor];
	NSInteger pixels;
	NSImage *image;
	NSSize natural;
	NSSize shown;
	CGFloat paneWidth;

	if (scale <= 0.0) {
		scale = 1.0;
	}
	pixels = (NSInteger)(WSInfoPreviewSize * scale + 0.5);
	(void)[[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];
	image = [WSItemIcons cg_pictureForPath:path box:pixels];
	if (image == nil) {
		image = [WSItemIcons iconForPath:path isDirectory:isDirectory size:pixels];
	}
	[_previewView setImage:image];
	if (_previewBody == nil) {
		return;
	}
	paneWidth = [_previewBody frame].size.width;
	if (image == nil) {
		[_previewView setFrame:NSMakeRect((paneWidth - WSInfoPreviewSize) / 2.0, 6.0,
						  WSInfoPreviewSize, WSInfoPreviewSize)];
		[_previewBody setFrameSize:NSMakeSize(paneWidth, WSInfoPreviewSize + 12.0)];
		return;
	}
	natural = [image size];
	shown = NSMakeSize(natural.width / scale, natural.height / scale);
	if (shown.width > WSInfoPreviewSize) {
		shown.height *= WSInfoPreviewSize / shown.width;
		shown.width = WSInfoPreviewSize;
	}
	if (shown.height > WSInfoPreviewSize) {
		shown.width *= WSInfoPreviewSize / shown.height;
		shown.height = WSInfoPreviewSize;
	}
	[_previewView setFrame:NSMakeRect((paneWidth - shown.width) / 2.0, 6.0, shown.width, shown.height)];
	[_previewBody setFrameSize:NSMakeSize(paneWidth, shown.height + 12.0)];
}

/* **A ROW WITHOUT AN ANSWER IS NOT A ROW.** This substrate records no birth time, so `-creationDate` is nil for every
 * item here; printing "Created: —" would be a line of the window that never has anything to say. The row is HIDDEN and
 * the rows under it move up, and the body shrinks by exactly one row — which is also why the window (which fits its
 * sections) gets 17 points shorter. The positions are computed from scratch on every pass rather than shifted, so a
 * file system that DOES report a creation time gets its row back without a second code path. */
- (void)cg_layoutGeneralRows
{
	NSTextField *keys[5];
	NSTextField *values[5];
	NSUInteger count = 0;
	NSUInteger i;
	BOOL hasCreation = ([_info creationDate] != nil);
	CGFloat width = [_generalBody frame].size.width;
	CGFloat y = 0.0;

	keys[count] = _kindKey; values[count] = _kindValue; count++;
	keys[count] = _sizeKey; values[count] = _sizeValue; count++;
	keys[count] = _whereKey; values[count] = _whereValue; count++;
	if (hasCreation) {
		keys[count] = _createdKey; values[count] = _createdValue; count++;
	}
	keys[count] = _modifiedKey; values[count] = _modifiedValue; count++;

	[_createdKey setHidden:!hasCreation];
	[_createdValue setHidden:!hasCreation];
	for (i = 0; i < count; i++) {
		[keys[i] setFrame:NSMakeRect(0.0, y, WSInfoKeyWidth, WSInfoRowHeight)];
		[values[i] setFrame:NSMakeRect(WSInfoKeyWidth + 8.0, y, width - WSInfoKeyWidth - 8.0, WSInfoRowHeight)];
		y += WSInfoRowHeight;
	}
	y += 6.0;
	[_sharedButton setFrame:NSMakeRect(WSInfoKeyWidth, y, width - WSInfoKeyWidth, 18.0)];
	y += 20.0;
	[_lockedButton setFrame:NSMakeRect(WSInfoKeyWidth, y, width - WSInfoKeyWidth, 18.0)];
	[_generalBody setFrameSize:NSMakeSize(width, y + 18.0 + 11.0)];
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
	[self cg_layoutGeneralRows];
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
	[self cg_updatePreview];

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
	[self cg_startSizeMeasure];
}

- (void)cg_layout
{
	CGFloat height = [(WSInfoDocumentView *)_documentView cg_layoutWidth:WSInfoWindowWidth];

	[self cg_fitWindowToHeight:height];
	[[self window] displayIfNeeded];
}

/* **THE WINDOW IS AS TALL AS ITS SECTIONS, UP TO A CEILING.** Folding one shrink-wraps the window instead of leaving a
 * lane of empty grey below it, and unfolding one grows it — with the TOP edge kept where it was, because that is the
 * edge a person is reading from and a window that grew upward would move the text under the pointer. Past the ceiling
 * (a big window's five open sections) the document scrolls, which is what the scroll view is for.
 *
 * **AND IT IS KEPT ON THE SCREEN.** Growing downward from a window that was centred can put the bottom edge below the
 * display, so the frame is pulled back inside the screen's own visible rectangle when there is a screen to ask — a
 * headless run has none, and then there is nothing to clamp to. */
- (void)cg_fitWindowToHeight:(CGFloat)height
{
	NSWindow *window = [self window];
	NSRect frame;
	CGFloat chrome;
	CGFloat wanted;
	NSScreen *screen;
	NSRect visible;

	if (window == nil) {
		return;
	}
	wanted = (height < WSInfoWindowMaxHeight) ? height : WSInfoWindowMaxHeight;
	if (wanted < WSInfoSectionHeight) {
		wanted = WSInfoSectionHeight;
	}
	frame = [window frame];
	chrome = frame.size.height - [[window contentView] frame].size.height;
	if (chrome < 0.0) {
		chrome = 0.0;
	}
	frame = NSMakeRect(frame.origin.x, NSMaxY(frame) - (wanted + chrome), frame.size.width, wanted + chrome);

	screen = [NSScreen mainScreen];
	if (screen != nil) {
		visible = [screen visibleFrame];
		if (NSMaxY(frame) > NSMaxY(visible)) {
			frame.origin.y = NSMaxY(visible) - frame.size.height;
		}
		if (frame.origin.y < NSMinY(visible)) {
			frame.origin.y = NSMinY(visible);
		}
	}
	[window setFrame:frame display:YES];
}

- (void)orderFront
{
	[self reload];
	[[self window] center];
	[[self window] makeKeyAndOrderFront:nil];
}

#pragma mark - The size of a folder

/* **A WALK IS STARTED ONLY WHEN THERE IS A FOLDER IN THE SELECTION AND ONLY ONCE PER SELECTION.** A file's size is its
 * own `stat` and is already right; a folder's is the tree under it, which MEASURED at 12.9 ms over 3,801 entries and
 * 7.7 s for `/usr` — so it is not a thing to do while building a window. The field says so in the meantime, which is
 * the honest picture: "Calculating…" is a number that is coming, and a wrong number is not.
 *
 * The controller RETAINS ITSELF for the duration: the walk outlives a window that is closed mid-walk, and the queued
 * continuation's target must still be an object when it fires. `-cg_setMeasuredBytes:...` releases that retain. */
- (void)cg_startSizeMeasure
{
	NSArray *paths = [_info paths];
	BOOL hasDirectory = NO;
	NSUInteger i;

	if (_measuring) {
		return;			/* one walk at a time; a second would answer about the same subject twice */
	}
	for (i = 0; i < [paths count]; i++) {
		struct stat s;

		if (stat([[paths objectAtIndex:i] fileSystemRepresentation], &s) == 0 && S_ISDIR(s.st_mode)) {
			hasDirectory = YES;
			break;
		}
	}
	if (!hasDirectory) {
		return;
	}
	_measuring = YES;
	[_sizeValue setStringValue:@"Calculating…"];
	[self retain];			/* released when the answer is put on the glass */
	[NSThread detachNewThreadSelector:@selector(cg_measureThread:) toTarget:self withObject:paths];
}

/* **THE THREAD TOUCHES NO VIEW, NO WINDOW AND NO IMAGE.** It walks with `lstat` and `opendir` and answers four numbers;
 * everything that draws happens in the continuation on the main thread. */
- (void)cg_measureThread:(NSArray *)paths
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	unsigned long long bytes = 0;
	unsigned long long onDisk = 0;
	unsigned long long items = 0;
	BOOL countsItems = NO;
	NSArray *result;

	[WSItemInfo cg_measurePaths:paths bytes:&bytes onDisk:&onDisk items:&items countsItems:&countsItems];
	result = [NSArray arrayWithObjects:[NSNumber numberWithUnsignedLongLong:bytes],
					   [NSNumber numberWithUnsignedLongLong:onDisk],
					   [NSNumber numberWithUnsignedLongLong:items],
					   [NSNumber numberWithBool:countsItems],
					   paths,
					   nil];
	[self performSelectorOnMainThread:@selector(cg_measureDone:) withObject:result waitUntilDone:NO];
	[pool release];
}

- (void)cg_measureDone:(NSArray *)result
{
	/* **AN ANSWER FOR A SELECTION THIS WINDOW NO LONGER SHOWS IS DROPPED**, and the retain `-cg_startSizeMeasure:` took
	 * is dropped with it: a rename or a navigation between the two can leave a walk talking about an old subject. */
	if (![[result lastObject] isEqualToArray:[_info paths]]) {
		_measuring = NO;
		[self autorelease];
		return;
	}
	[self cg_setMeasuredBytes:[[result objectAtIndex:0] unsignedLongLongValue]
			   onDisk:[[result objectAtIndex:1] unsignedLongLongValue]
			    items:(NSUInteger)[[result objectAtIndex:2] unsignedLongLongValue]
		      countsItems:[[result objectAtIndex:3] boolValue]];
	_measuring = NO;
	[self autorelease];		/* the start's retain */
}

- (void)cg_setMeasuredBytes:(unsigned long long)bytes
		     onDisk:(unsigned long long)onDisk
		      items:(NSUInteger)items
		countsItems:(BOOL)countsItems
{
	[_info cg_setBytes:bytes onDisk:onDisk items:items countsItems:countsItems];
	[self cg_updateFields];
	[self cg_layout];
}

- (BOOL)cg_isCalculatingSize
{
	return _measuring;
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
	/* **THE WINDOW'S SUBJECT IS THE NEW PATH, NOT THE OLD ONE.** `-reload` re-reads `-paths`, and the old name no longer
	 * exists — so the rename replaces the info rather than refreshing the one that pointed at where the file used to be. */
	{
		WSItemInfo *updated = [[WSItemInfo infoForPaths:[NSArray arrayWithObject:destination]] retain];

		[_info release];
		_info = updated;
	}
	[self cg_updateFields];
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

/* **THE FOUR CHOICES, AS A MENU, WITH THE ONE THAT IS TRUE TICKED.** A separate method so the menu can be read without
 * being popped up: a probe checks the titles, the order and which one is on, and the popping is the one line a display
 * is needed for. */
- (NSMenu *)cg_privilegeMenuForRow:(NSInteger)row
{
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Privilege"] autorelease];
	NSArray *titles = [WSItemInfo privilegeTitles];
	NSInteger current = [_info privilegeIndexForClass:row];
	NSUInteger i;

	for (i = 0; i < [titles count]; i++) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[titles objectAtIndex:i]
							     action:@selector(cg_privilegeChosen:)
						      keyEquivalent:@""];

		[item setTarget:self];
		[item setTag:(NSInteger)i];
		[item setState:((NSInteger)i == current) ? NSOnState : NSOffState];
		[menu addItem:item];
		[item release];
	}
	return menu;
}

- (void)permissionsTable:(NSTableView *)table showPrivilegeMenuForRow:(NSInteger)row atPoint:(NSPoint)point
{
	NSMenu *menu = [self cg_privilegeMenuForRow:row];

	_cgMenuRow = row;
	[menu popUpMenuPositioningItem:nil atLocation:point inView:table];
}

/* **THE PICK IS A CHMOD, AND THE WINDOW RE-READS AFTER IT.** The row IS the class — the table's three rows are the
 * owner, the group and everyone, in that order — and the item's tag is the choice; `WSItemInfo` does the bits so the
 * same door can be checked without a window. A refused chmod leaves the disk as it was, and the reload is what puts the
 * cell back on the truth rather than on the choice that did not happen. */
- (void)cg_privilegeChosen:(id)sender
{
	[self cg_applyPrivilegeIndex:[(NSMenuItem *)sender tag] forRow:_cgMenuRow];
}

- (void)cg_applyPrivilegeIndex:(NSInteger)index forRow:(NSInteger)row
{
	if (row < 0 || (NSUInteger)row >= [[_info permissions] count] || index < 0 || index > 3) {
		return;
	}
	(void)[WSItemInfo cg_setPrivilegeIndex:index forClass:row paths:[_info paths]];
	[self reload];
}

- (NSInteger)cg_privilegeIndexForRow:(NSInteger)row
{
	return [_info privilegeIndexForClass:row];
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

- (BOOL)cg_isSectionCollapsedAtIndex:(NSUInteger)index
{
	return (index < [_sections count]) ? [[_sections objectAtIndex:index] isCollapsed] : YES;
}

- (void)cg_setSectionAtIndex:(NSUInteger)index collapsed:(BOOL)collapsed
{
	if (index >= [_sections count]) {
		return;
	}
	[[_sections objectAtIndex:index] cg_setCollapsed:collapsed];
	[self cg_layout];
}

@end
