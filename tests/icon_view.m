/*
 * icon_view — W3's icon view: the grid, the keyboard, rename, and the drop policies.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE THREE HALVES ARE ASKED SEPARATELY.** The GRID is `WSIconLayout`'s left-to-right row order; the KEYBOARD and
 * TYPE-SELECT are `WSIconView`'s own state; the RENAME is a field over the label and an `NSFileManager` move; and the
 * DROP is the pasteboard's paths plus the policy arithmetic (same volume -> Move, across -> Copy, Command+Option ->
 * Link) and the file operation each policy performs. Offscreen, with a temporary tree on `/tmp` and a second on
 * `/dev/shm` so "across a volume" is a fact rather than a claim.
 */
#import "WSIconLabel.h"
#import "WSIconCell.h"
#import "WSIconLayout.h"
#import "WSDesktopView.h"
#import "WSIconView.h"
#import "WSItemModel.h"
#import "WSSelectionBand.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSDragging.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSPasteboard.h>
#import <AppKit/NSStringDrawing.h>
#import <AppKit/NSText.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <stdio.h>
#include <unistd.h>

static int s_failed;

static void check(int ok, const char *name)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", name);
	if (!ok) {
		s_failed++;
	}
}

static int near(double a, double b)
{
	return a > b - 0.01 && a < b + 0.01;
}

static BOOL makeDirectory(NSString *path)
{
	return [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
								  attributes:nil error:NULL];
}

static BOOL makeFile(NSString *path)
{
	return [[NSFileManager defaultManager] createFileAtPath:path contents:[NSData data] attributes:nil];
}

static NSEvent *key(unichar character, NSUInteger flags)
{
	NSString *string = [NSString stringWithCharacters:&character length:1];

	return [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:flags
			       timestamp:0.0 windowNumber:0 context:nil
				characters:string charactersIgnoringModifiers:string
				isARepeat:NO keyCode:0];
}

/* **A VIEW PAINTED INTO A BITMAP, so the band's two colours are measured rather than asserted.** The white underlay
 * matters: the band is SEMITRANSPARENT, so what it looks like is the accent over whatever is beneath — and a probe that
 * drew it over black would be measuring a different colour. */
static NSBitmapImageRep *new_rep(int width, int height)
{
	return [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32];
}

static NSBitmapImageRep *draw_view_over(NSView *view, int width, int height, NSColor *background)
{
	NSBitmapImageRep *rep = new_rep(width, height);

	[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
	[background setFill];
	[[NSBezierPath bezierPathWithRect:NSMakeRect(0.0, 0.0, (CGFloat)width, (CGFloat)height)] fill];
	[view drawRect:[view bounds]];
	return rep;
}

static NSBitmapImageRep *draw_view(NSView *view, int width, int height)
{
	return draw_view_over(view, width, height, [NSColor whiteColor]);
}

/* **WHERE THE SELECTION'S WASH IS, in a rep.** The wash is the accent at 35% over white, so the pixels it tints have one
 * exact colour; the icon drawn on top of it does not, which is what leaves the wash visible around the icon and gives the
 * rectangle its bounds. */
static NSRect wash_bounds(NSBitmapImageRep *rep, int width, int height)
{
	int x, y;
	int minX = width, minY = height, maxX = -1, maxY = -1;
	/* The wash is a fill with an alpha, so what a rep shows is it composited over the white the view painted first. */
	NSColor *wash = WSIconCellSelectionColor();
	CGFloat alpha = [wash alphaComponent];
	CGFloat wantR = alpha * [wash redComponent] + (1.0 - alpha);
	CGFloat wantG = alpha * [wash greenComponent] + (1.0 - alpha);
	CGFloat wantB = alpha * [wash blueComponent] + (1.0 - alpha);

	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			NSColor *c = [rep colorAtX:x y:y];

			if (c == nil || fabs([c redComponent] - wantR) > 0.02 || fabs([c greenComponent] - wantG) > 0.02
			    || fabs([c blueComponent] - wantB) > 0.02) {
				continue;
			}
			if (x < minX) minX = x;
			if (y < minY) minY = y;
			if (x > maxX) maxX = x;
			if (y > maxY) maxY = y;
		}
	}
	if (maxX < 0) {
		return NSZeroRect;
	}
	return NSMakeRect((CGFloat)minX, (CGFloat)minY, (CGFloat)(maxX - minX + 1), (CGFloat)(maxY - minY + 1));
}

static NSEvent *mouse(NSEventType type, NSPoint point)
{
	return [NSEvent mouseEventWithType:type location:point modifierFlags:0
				 timestamp:0.0 windowNumber:0 context:nil
				 eventNumber:0 clickCount:1 pressure:1.0f];
}

static NSInteger indexNamed(WSIconView *view, NSString *name)
{
	NSArray *items = [[view model] items];
	NSUInteger i;

	for (i = 0; i < [items count]; i++) {
		if ([[[items objectAtIndex:i] name] isEqual:name]) {
			return (NSInteger)i;
		}
	}
	return -1;
}

/* THE UNION OF THE VIEW'S INVALIDATED RECTANGLES: the window's private seam, declared here as the other probes do. */
@interface NSView (AGIconDamageProbe)
- (NSRect)cg_dirtyUnion;
@end

@interface WSIconView (AGIconBandProbe)
- (NSRect)cg_bandRect;
@end

/* The desktop's own probe doors, declared as its test declares them. */
@interface WSDesktopView (AGIconSelectionProbe)
- (NSArray *)cg_selection;
- (NSArray *)cg_positions;
- (NSRect)cg_highlightRectAtIndex:(NSInteger)index;
@end

@interface NSApplication (APPKITIconProbe)
- (void)cg_addWindow:(NSWindow *)window;
- (void)cg_removeWindow:(NSWindow *)window;
@end

static NSPoint centerOfIndex(WSIconView *view, NSInteger index)
{
	NSArray *positions = [view cg_positions];
	NSPoint position = [[positions objectAtIndex:(NSUInteger)index] pointValue];

	return NSMakePoint(position.x + 32.0, position.y + 32.0);
}

/* ---- A DRAGGING INFO WITHOUT A SESSION ------------------------------------------------------- */

@interface AGDropInfo : NSObject <NSDraggingInfo>
{
	NSPasteboard *_pasteboard;	/* RETAINED */
	NSPoint _location;
	NSDragOperation _mask;
	id _source;			/* NOT RETAINED */
}
- (instancetype)initWithPaths:(NSArray *)paths location:(NSPoint)location mask:(NSDragOperation)mask;
@end

@implementation AGDropInfo
- (instancetype)initWithPaths:(NSArray *)paths location:(NSPoint)location mask:(NSDragOperation)mask
{
	self = [super init];
	if (self != nil) {
		_pasteboard = [[NSPasteboard pasteboardWithUniqueName] retain];
		[_pasteboard declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType] owner:nil];
		[_pasteboard setPropertyList:paths forType:NSFilenamesPboardType];
		_location = location;
		_mask = mask;
	}
	return self;
}
- (void)dealloc
{
	[_pasteboard release];
	[super dealloc];
}
- (NSWindow *)draggingDestinationWindow { return nil; }
- (NSDragOperation)draggingSourceOperationMask { return _mask; }
- (NSPoint)draggingLocation { return _location; }
- (NSPoint)draggedImageLocation { return NSZeroPoint; }
- (NSImage *)draggedImage { return nil; }
- (NSPasteboard *)draggingPasteboard { return _pasteboard; }
- (id)draggingSource { return _source; }
- (NSInteger)draggingSequenceNumber { return 1; }
- (void)slideDraggedImageTo:(NSPoint)screenPoint { (void)screenPoint; }
- (NSArray *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination
{
	(void)dropDestination;
	return nil;
}
- (void)setSource:(id)source { _source = source; }
@end

/* ---- A DELEGATE THAT RECORDS OPENS ---------------------------------------------------------- */

@interface AGIconProbe : NSObject <WSIconViewDelegate>
{
@public
	NSString *opened;
	int changes;
}
@end

@implementation AGIconProbe
- (void)iconView:(WSIconView *)view openItem:(WSItem *)item
{
	(void)view;
	[opened release];
	opened = [[item name] copy];
}
- (void)iconViewDidChangeModel:(WSIconView *)view
{
	(void)view;
	changes++;
}
- (void)dealloc
{
	[opened release];
	[super dealloc];
}
@end

/* ---- A SPRING OBSERVER ---------------------------------------------------------------------- */

@interface AGSpringProbe : NSObject
{
@public
	NSString *path;
	int requests;
}
@end

@implementation AGSpringProbe
- (void)requested:(NSNotification *)notification
{
	requests++;
	[path release];
	path = [[[notification userInfo] objectForKey:WSIconViewFolderPathKey] copy];
}
- (void)dealloc
{
	[path release];
	[super dealloc];
}
@end

int main(void)
{
	NSApplication *application = [NSApplication sharedApplication];
	NSString *root = [@"/tmp" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"agora-icon-view-%d", (int)getpid()]];
	NSString *sourceRoot = [@"/tmp" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"agora-icon-source-%d", (int)getpid()]];
	NSString *otherRoot = [@"/dev/shm" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"agora-icon-other-%d", (int)getpid()]];
	NSString *target = [root stringByAppendingPathComponent:@"Target"];
	NSString *otherTarget = [otherRoot stringByAppendingPathComponent:@"Dest"];
	WSItemModel *model;
	WSIconView *view;
	NSWindow *window;
	AGIconProbe *probe;
	AGSpringProbe *spring;

	setvbuf(stdout, NULL, _IONBF, 0);
	[application finishLaunching];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:sourceRoot error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:otherRoot error:NULL];
	check(makeDirectory(root), "the probe made the temporary tree");
	makeDirectory(target);
	makeDirectory(sourceRoot);
	makeFile([sourceRoot stringByAppendingPathComponent:@"move.txt"]);
	makeFile([sourceRoot stringByAppendingPathComponent:@"copy.txt"]);
	makeFile([sourceRoot stringByAppendingPathComponent:@"link.txt"]);
	makeFile([sourceRoot stringByAppendingPathComponent:@"into-folder.txt"]);
	makeDirectory(otherRoot);
	makeDirectory(otherTarget);
	makeDirectory([root stringByAppendingPathComponent:@"Archive"]);
	makeDirectory([root stringByAppendingPathComponent:@"Documents"]);
	makeFile([root stringByAppendingPathComponent:@"delta.txt"]);
	makeFile([root stringByAppendingPathComponent:@"notes.txt"]);

	model = [[WSItemModel alloc] initWithDirectory:root];
	view = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0) model:model];
	window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 400.0, 400.0)
					     styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
	[window setContentView:view];
	probe = [[AGIconProbe alloc] init];
	[view setDelegate:probe];

	/* 0. THE LABEL IS CUT TO THE CELL, NOT TO ITS OWN MEASURED WIDTH. */
	{
		NSDictionary *attributes = [NSDictionary dictionary];
		NSString *shortName = WSIconLabelText(@"notes.txt", 76.0, attributes);
		NSString *longName = WSIconLabelText(@"64 Ultimax Banked Cartridge Template", 76.0, attributes);

		check([shortName isEqual:@"notes.txt"], "a short name is unchanged");
		check([longName length] < [@"64 Ultimax Banked Cartridge Template" length]
		      && [longName rangeOfString:@"…"].location != NSNotFound,
		      "a long name is cut in the middle with an ellipsis");
		check([longName sizeWithAttributes:attributes].width <= 76.01,
		      "and the cut label fits the cell it is drawn in");
	}

	/* 1. THE GRID IS THE DESKTOP'S ENGINE IN THE FILE WINDOW'S ORDER. */
	check(near([[[view cg_positions] objectAtIndex:0] pointValue].x, 16.0)
	      && near([[[view cg_positions] objectAtIndex:0] pointValue].y, 16.0),
	      "the first cell is the top-left margin");
	check(near([[[view cg_positions] objectAtIndex:1] pointValue].x, 96.0)
	      && near([[[view cg_positions] objectAtIndex:1] pointValue].y, 16.0),
	      "the second item is one cell to the RIGHT, in the same row");
	check(near([[[view cg_positions] objectAtIndex:4] pointValue].x, 16.0)
	      && near([[[view cg_positions] objectAtIndex:4] pointValue].y, 104.0),
	      "and the fifth wraps to the next ROW at the left edge");
	check(near([view contentHeightForWidth:400.0], 192.0), "two rows make a 192-point document");

	/* 1b. **ONE RECTANGLE WEARS BOTH THE WASH AND THE RING, CENTRED ON THE ICON AND CLEAR OF THE NAME.** The wash used
	 * to be the cell's — which carries its padding to the right and above, so it sat off-centre on the folder — while the
	 * ring was the bare icon's, two points out, with its top edge on the label's first line. The names below are the
	 * arithmetic that made the screenshot wrong. */
	{
		NSRect icon = NSMakeRect([[[view cg_positions] objectAtIndex:0] pointValue].x,
					  [[[view cg_positions] objectAtIndex:0] pointValue].y, 64.0, 64.0);
		NSRect highlight = [view cg_highlightRectAtIndex:0];
		CGFloat labelTop = NSMaxY(icon) + 2.0 + 16.0;	/* the icon, the gap, the label height */

		check(near(NSMidX(highlight), NSMidX(icon)),
		      "the selection's rectangle is centred on the icon, not on the cell's padding");
		check(near(highlight.size.width, 80.0),
		      "it is one cell wide, so neighbours never share a wash");
		check(NSMinY(highlight) < NSMinY(icon) && NSMaxY(highlight) > labelTop,
		      "and it encloses the icon and the whole label band");
	}

	/* 1c. **A SELECTION THAT MOVES ONE CELL REPAINTS ONE CELL.** The view used to answer a click with
	 * `-setNeedsDisplay:`, which is "all of me": the window then drew every folder and every name and copied the whole
	 * frame to move a wash from one cell to the next — MEASURED at 20-45 ms a click against 3-7 ms for the cells. So
	 * what is asserted here is the SHAPE of the invalidation: the cell that was selected, the cell that now is, and
	 * nothing else in the grid. */
	[view setNeedsDisplay:NO];
	[view selectIndex:0];
	{
		NSRect first = [view cg_highlightRectAtIndex:0];
		NSRect second = [view cg_highlightRectAtIndex:1];
		NSRect elsewhere = [view cg_highlightRectAtIndex:[view itemCount] - 1];

		check([view needsDisplayInRect:first], "selecting a cell invalidates that cell");
		/* **AND THE RING IS ON THE CELL'S EDGE, SO ITS STROKE IS OUTSIDE THE CELL.** A one-point stroke centred on
		 * the highlight's edge paints half a point beyond it and antialiases a point either side; an invalidation
		 * that stopped at the rectangle left a thin outline behind in the cell the selection had left. */
		check(NSEqualRects([view cg_dirtyUnion], NSInsetRect(first, -2.0, -2.0)),
		      "and the damage reaches two points past it, which is what erases the ring stroked on the edge");
		check(![view needsDisplayInRect:elsewhere],
		      "and not the rest of the grid, which is what makes a click a two-cell paint");

		[view setNeedsDisplay:NO];
		[view selectIndex:1];
		check([view needsDisplayInRect:first] && [view needsDisplayInRect:second],
		      "moving the selection invalidates the cell it left AND the cell it entered");
		check(![view needsDisplayInRect:elsewhere], "and still nothing else");
	}

	/* 1d. **A PRESS IN THE EMPTY SPACE BEGINS A BAND, AND THE BAND IS DRAWN.** There was no gesture: every press between
	 * icons cleared the selection and stopped, so several icons could only be taken with the keyboard. What is asserted
	 * is the three things a band is — the rectangle it reports, the damage it asks for, and the two colours it paints (an
	 * accent wash inside a darker edge), sampled out of a real draw.
	 *
	 * **THE PAINT IS MEASURED OVER THE VIEW'S OWN WHITE**, so the band used for it is the narrow strip left of the first
	 * column: over a folder's blue artwork the wash tints the picture, and the question "which colour is the band" would
	 * be answered by the picture instead. The strip is also SYMMETRIC about the view's middle (y 100..300 of 400), so the
	 * sample point is the same row whichever way a bitmap counts its rows. */
	{
		NSPoint paintStart = NSMakePoint(2.0, 100.0);
		NSPoint paintEnd = NSMakePoint(6.0, 300.0);	/* it must stop short of the first cell's wash at x 8 */
		NSPoint start = NSMakePoint(2.0, 2.0);		/* the gesture: an empty corner, across the first icon */
		NSPoint end = NSMakePoint(70.0, 55.0);
		NSRect band;
		NSBitmapImageRep *rep;
		NSColor *inside;
		NSColor *edge;
		NSColor *outside;

		[view selectIndex:-1];
		[view setNeedsDisplay:NO];
		[view mouseDown:mouse(NSLeftMouseDown, [view convertPoint:paintStart toView:nil])];
		[view mouseDragged:mouse(NSLeftMouseDragged, [view convertPoint:paintEnd toView:nil])];
		band = [view cg_bandRect];
		check(near(NSMinX(band), 2.0) && near(NSMinY(band), 100.0)
		      && near(NSWidth(band), 4.0) && near(NSHeight(band), 200.0),
		      "the band is the rectangle between the press and the pointer, in either direction");
		check(NSContainsRect([view cg_dirtyUnion], NSInsetRect(band, -2.0, -2.0)),
		      "and the damage covers it, with the margin the hairline needs");

		rep = draw_view(view, 400, 400);
		inside = [rep colorAtX:4 y:200];
		edge = [rep colorAtX:2 y:200];
		outside = [rep colorAtX:380 y:380];
		/* **THE FILL IS THE ACCENT AT ITS STATED ALPHA OVER WHITE** — not "a blue something". The expectation is computed
		 * from `+cg_accentColor` and `WSSelectionBandFillAlpha`, so a hue or an alpha change shows up here. */
		{
			NSColor *accent = [[NSColor cg_accentColor] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];

			if (accent == nil) {
				accent = [NSColor cg_accentColor];	/* already an RGB colour; the conversion refuses its own space */
			}
			{
				CGFloat alpha = WSSelectionBandFillAlpha;
				CGFloat r = alpha * [accent redComponent] + (1.0 - alpha);
				CGFloat g = alpha * [accent greenComponent] + (1.0 - alpha);
				CGFloat b = alpha * [accent blueComponent] + (1.0 - alpha);

				check(inside != nil && near([inside redComponent], r) && near([inside greenComponent], g)
				      && near([inside blueComponent], b),
				      "the band's fill is the accent at its stated alpha over the view's white");
				check(inside != nil && [inside redComponent] < 0.999,
				      "and it is SEMITRANSPARENT — white shows through it");
			}
		}
		check(edge != nil && [edge blueComponent] < [inside blueComponent] - 0.2,
		      "the border is a darker shade of that same accent");
		check(outside != nil && [outside redComponent] > 0.999 && [outside greenComponent] > 0.999
		      && [outside blueComponent] > 0.999,
		      "and outside the band the view is untouched white");
		[view mouseUp:mouse(NSLeftMouseUp, [view convertPoint:paintEnd toView:nil])];
		check([[view selectedIndexes] count] == 0, "a band over the empty margin selects nothing");
		check(NSEqualRects([view cg_bandRect], NSZeroRect), "and the band is gone");

		/* **THE SELECTION IS APPLIED WHEN THE BUTTON COMES UP**, which is the desktop's own rule: a drag across the grid
		 * must not repaint the selection under the hand that is following it. */
		[view mouseDown:mouse(NSLeftMouseDown, [view convertPoint:start toView:nil])];
		[view mouseDragged:mouse(NSLeftMouseDragged, [view convertPoint:end toView:nil])];
		check([[view selectedIndexes] count] == 0, "nothing is selected while the band is still being dragged");
		[view mouseUp:mouse(NSLeftMouseUp, [view convertPoint:end toView:nil])];
		check([[view selectedIndexes] count] == 1 && [[view selectedIndexes] containsIndex:0],
		      "letting go selects the one item the band touched");

		/* **AND A SHIFT-BAND ADDS TO WHAT WAS CHOSEN** rather than replacing it, which is the only reason to press in the
		 * empty space with Shift held. */
		[view selectIndex:3];
		{
			NSEvent *down = [NSEvent mouseEventWithType:NSLeftMouseDown
							  location:[view convertPoint:start toView:nil]
						     modifierFlags:NSShiftKeyMask timestamp:0.0 windowNumber:0 context:nil
						       eventNumber:0 clickCount:1 pressure:1.0f];

			[view mouseDown:down];
			[view mouseDragged:mouse(NSLeftMouseDragged, [view convertPoint:end toView:nil])];
			[view mouseUp:mouse(NSLeftMouseUp, [view convertPoint:end toView:nil])];
		}
		check([[view selectedIndexes] containsIndex:3] && [[view selectedIndexes] containsIndex:0],
		      "a Shift-band keeps the item that was already selected and adds the ones it touches");
	}

	/* 1e. **ONE SELECTION FOR THE WHOLE WORKSPACE.** The desktop and every file window are separate views with
	 * separate models, and their highlights were separate too — an icon could be chosen on the desktop and another in
	 * each open window at once, which says "these are all chosen" about files in three different folders. Choosing in one
	 * surface now takes the selection away from every other, and clearing one's own (a press in the empty space) is NOT
	 * choosing, so the window next door keeps what it had. */
	{
		WSItemModel *otherModel = [[WSItemModel alloc] initWithDirectory:otherRoot];
		WSIconView *second = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								 model:otherModel];
		NSWindow *secondWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								     styleMask:NSBorderlessWindowMask
								       backing:NSBackingStoreBuffered defer:NO];
		WSDesktopView *desktop = [[WSDesktopView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 520.0, 400.0)
								     directory:root];
		NSWindow *desktopWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 520.0, 400.0)
								      styleMask:NSBorderlessWindowMask
									backing:NSBackingStoreBuffered defer:NO];

		[secondWindow setContentView:second];
		[desktopWindow setContentView:desktop];
		[otherModel release];

		/* A SELECTS: the other window and the desktop are empty. */
		[view selectIndex:1];
		check([[view selectedIndexes] count] == 1, "the window that chose holds the selection");
		check([[second selectedIndexes] count] == 0, "the window next door lets go of its own");
		check([[desktop cg_selection] count] == 0, "and so does the desktop");

		/* B SELECTS: the first window is empty. */
		[second selectIndex:0];
		check([[second selectedIndexes] count] == 1, "choosing in the second window takes the selection");
		check([[view selectedIndexes] count] == 0, "the first window lets go");

		/* THE DESKTOP SELECTS — through the mouse, which is the only way it chooses: the first icon's cell. */
		{
			NSPoint position = [[[desktop cg_positions] objectAtIndex:0] pointValue];
			NSRect bounds = [desktop bounds];
			NSPoint windowPoint = NSMakePoint(position.x + 32.0, bounds.size.height - (position.y + 32.0));
			NSEvent *down = mouse(NSLeftMouseDown, windowPoint);
			NSEvent *up = mouse(NSLeftMouseUp, windowPoint);

			[desktop mouseDown:down];
			[desktop mouseUp:up];
		}
		check([[desktop cg_selection] count] == 1, "the desktop holds the selection after a click on one of its icons");
		check([[view selectedIndexes] count] == 0 && [[second selectedIndexes] count] == 0,
		      "and both windows let go of theirs");

		/* AND BACK: a window choosing takes it off the desktop. */
		[view selectIndex:0];
		check([[view selectedIndexes] count] == 1 && [[desktop cg_selection] count] == 0,
		      "a window choosing takes the selection off the desktop");

		/* **CLEARING IS NOT CHOOSING.** A press in the empty space of the second window empties only itself, so the first
		 * window keeps the icon it holds — which is what makes "the selection moved" different from "nothing was chosen
		 * here". */
		{
			NSPoint empty = NSMakePoint(380.0, 380.0);	/* below the second window's items */

			[second mouseDown:mouse(NSLeftMouseDown, [second convertPoint:empty toView:nil])];
			[second mouseUp:mouse(NSLeftMouseUp, [second convertPoint:empty toView:nil])];
		}
		check([[second selectedIndexes] count] == 0, "the emptied window has nothing selected");
		check([[view selectedIndexes] count] == 1, "and the window that held the selection still does");

		/* **AND THE SPACE BETWEEN AN ICON AND ITS NAME IS ONE NUMBER, MEASURED ON BOTH.** A rep's rows run from its own
		 * first one and the two views disagree about which end that is, so each gap is taken in VISUAL terms: away from the
		 * icon, downward on the screen. What is asserted is that the two agree — the first row of ink is the same distance
		 * below the icon on a desktop and in a file window — and that the distance is a sane one rather than a number that
		 * happens to match because both surfaces stopped drawing. */
		{
			NSBitmapImageRep *viewRep = draw_view(view, 400, 400);
			NSBitmapImageRep *deskRep = draw_view_over(desktop, 520, 400,
								   [NSColor colorWithCalibratedRed:0.10 green:0.20 blue:0.09 alpha:1.0]);
			NSPoint dp = [[[desktop cg_positions] objectAtIndex:0] pointValue];
			int deskIconBottomRow = (int)dp.y + (int)[desktop iconSize];
			int viewIconBottomRow = 400 - ((int)[desktop iconSize] + 16);	/* view y 80, and this rep counts from the top */
			int y, x, viewFirst = -1, deskFirst = -1;
			int viewGap, deskGap;

			for (y = viewIconBottomRow; y > viewIconBottomRow - 40 && viewFirst < 0; y--) {
				for (x = 16; x < 96; x++) {
					NSColor *c = [viewRep colorAtX:x y:y];

					if (c != nil && [c redComponent] < 0.45 && [c greenComponent] < 0.45) {
						viewFirst = y;
						break;
					}
				}
			}
			for (y = deskIconBottomRow; y < deskIconBottomRow + 40 && y < 400 && deskFirst < 0; y++) {
				for (x = (int)dp.x; x < (int)dp.x + 80; x++) {
					NSColor *c = [deskRep colorAtX:x y:y];

					if (c != nil && [c redComponent] > 0.85 && [c greenComponent] > 0.85
					    && [c blueComponent] > 0.85) {
						deskFirst = y;
						break;
					}
				}
			}
			viewGap = viewIconBottomRow - viewFirst;
			deskGap = deskFirst - deskIconBottomRow;
			check(viewFirst >= 0 && deskFirst >= 0, "both surfaces draw a name under their icon");
			check(viewGap == deskGap,
			      "and the space between the icon and the first row of ink is the SAME on both");
			check(viewGap >= 2 && viewGap <= 8,
			      "which is a gap rather than the icon touching its name, and not a margin");
		}

		/* THE VIEWS STAY: they registered for the shared selection, and the tier's centre holds them WEAKLY — a view
		 * released here is not the test's to free while a post could still be in flight. A probe leaks four objects. */
		(void)desktop;
		(void)second;
		(void)desktopWindow;
		(void)secondWindow;
	}

	/* 1f. **THE DESKTOP AND A FILE WINDOW DRAW THE SAME SELECTED CELL.** The complaint was visual: a desktop selection was
	 * a square four points outside the icon, unrounded and stopping above the name, while a file window's was a rounded
	 * rectangle the width of the cell that enclosed the label. Two questions, asked two ways: the RECTANGLE each view
	 * answers (exact, and where the geometry lives) and the WASH each view actually paints (the thing a person sees, and
	 * the reason the rectangle cannot be believed on its own). */
	{
		WSDesktopView *desktop = [[WSDesktopView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 520.0, 400.0)
								     directory:root];
		NSWindow *desktopWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 520.0, 400.0)
								      styleMask:NSBorderlessWindowMask
									backing:NSBackingStoreBuffered defer:NO];
		NSSize cell = [WSIconLayout cellSizeForIconSize:[desktop iconSize]];
		CGFloat wantWidth = cell.width;
		CGFloat wantHeight = (CGFloat)[desktop iconSize] + (CGFloat)WSIconLabelGap
			+ (CGFloat)WSIconLabelHeight + 2.0 * (CGFloat)WSIconHighlightInset;
		NSRect iconWash;
		NSRect desktopWash;

		[desktopWindow setContentView:desktop];

		[view selectIndex:0];
		iconWash = wash_bounds(draw_view(view, 400, 400), 400, 400);
		/* The corners are rounded, so the outermost rows and columns are only PARTLY tinted and the pure-colour box is a
		 * point or two inside the rectangle. What it pins is the thing that changed: the wash reaches past the icon. */
		check(NSWidth(iconWash) > (CGFloat)WSIconDefaultSize + 4.0
		      && NSHeight(iconWash) > (CGFloat)WSIconDefaultSize + 8.0,
		      "a file window's wash is wider than the icon and tall enough for the name");

		{
			NSPoint position = [[[desktop cg_positions] objectAtIndex:0] pointValue];
			NSRect bounds = [desktop bounds];
			NSPoint windowPoint = NSMakePoint(position.x + 32.0, bounds.size.height - (position.y + 32.0));

			[desktop mouseDown:mouse(NSLeftMouseDown, windowPoint)];
			[desktop mouseUp:mouse(NSLeftMouseUp, windowPoint)];
		}
		/* Over the white a file window paints, so the SHAPE can be compared: the wash is semitransparent, so its colour
		 * depends on the background and only this page makes the two surfaces' pixels comparable. */
		desktopWash = wash_bounds(draw_view(desktop, 520, 400), 520, 400);
		/* **AND THE WASH IS SEMITRANSPARENT ON BOTH.** The accent is a fill with an alpha, so what a person sees is it
		 * composited over whatever is behind the cell — a white page, a wallpaper, another window. So the desktop is
		 * painted over TWO backgrounds, and the same point inside the highlight must be two different colours, each of
		 * them the same blend: that is what "semitransparent" means, and a plate of white under the wash would fail it. */
		check(near(NSWidth(desktopWash), NSWidth(iconWash)) && near(NSHeight(desktopWash), NSHeight(iconWash)),
		      "and the desktop paints the SAME wash rectangle as a file window");
		{
			NSColor *dark = [NSColor colorWithCalibratedRed:0.10 green:0.20 blue:0.09 alpha:1.0];
			NSBitmapImageRep *overGreen = draw_view_over(desktop, 520, 400, dark);
			NSBitmapImageRep *overWhite = draw_view(desktop, 520, 400);
			NSRect highlight = [desktop cg_highlightRectAtIndex:0];
			NSInteger sx = (NSInteger)NSMinX(highlight) + 3;
			NSInteger syTop = (NSInteger)(400.0 - NSMidY(highlight));	/* this rep counts its rows from the top */
			NSColor *onGreen = [overGreen colorAtX:sx y:syTop];
			NSColor *onWhite = [overWhite colorAtX:sx y:syTop];
			NSColor *wash = WSIconCellSelectionColor();
			CGFloat a = [wash alphaComponent];
			CGFloat wantR = a * [wash redComponent] + (1.0 - a) * [dark redComponent];
			CGFloat wantG = a * [wash greenComponent] + (1.0 - a) * [dark greenComponent];
			CGFloat wantB = a * [wash blueComponent] + (1.0 - a) * [dark blueComponent];

			check(onGreen != nil && near([onGreen redComponent], wantR) && near([onGreen greenComponent], wantG)
			      && near([onGreen blueComponent], wantB),
			      "the wash over a wallpaper is the accent at its own alpha, not a plate");
			check(onWhite != nil && near([onWhite redComponent], a * [wash redComponent] + (1.0 - a))
			      && near([onWhite blueComponent], a * [wash blueComponent] + (1.0 - a)),
			      "and over a white page it is the same alpha over that page");
			check(onGreen != nil && onWhite != nil
			      && (fabs([onGreen redComponent] - [onWhite redComponent]) > 0.2),
			      "so the background shows THROUGH the selection");
		}
		/* **AND THE DESKTOP'S NAME IS WHITE WITH A BLACK SHADOW; A FILE WINDOW'S IS BLACK WITH NONE.** White ink over a
		 * wallpaper needs an edge a white page never asks for, so the desktop draws the same name once in black, one
		 * point down and right, before the white. Painted over a WHITE page — where white ink is invisible — the only
		 * thing that can leave a dark pixel under the icon is that shadow. */
		{
			NSBitmapImageRep *page = draw_view(desktop, 520, 400);
			NSRect highlight = [desktop cg_highlightRectAtIndex:0];
			int yTop = (int)(400.0 - NSMidY(highlight));	/* the name hangs below the icon */
			int yBottom = (int)(400.0 - NSMinY(highlight));
			int dark = 0, x, y;

			for (y = yTop; y < yBottom; y++) {
				for (x = (int)NSMinX(highlight); x < (int)NSMaxX(highlight); x++) {
					NSColor *c = [page colorAtX:x y:y];

					if (c != nil && [c redComponent] < 0.25 && [c greenComponent] < 0.25
					    && [c blueComponent] < 0.25) {
						dark++;
					}
				}
			}
			check(dark > 4,
			      "and a desktop name is white with a BLACK SHADOW — over a white page its ink is invisible, its shadow is not");
		}

		/* **AND THE RECTANGLES ARE THE SAME SHAPE**, which the pixels cannot say — the desktop's first icon sits against
		 * the edge of its view, so its wash is clipped. Each view answers the rectangle it fills; what is compared is its
		 * size and its position RELATIVE to the icon, so two different layouts are held to one presentation. */
		{
			NSPoint viewIconPosition = [[[view cg_positions] objectAtIndex:0] pointValue];
			NSRect viewIcon = NSMakeRect(viewIconPosition.x, viewIconPosition.y,
						     (CGFloat)WSIconDefaultSize, (CGFloat)WSIconDefaultSize);
			NSRect inView = [view cg_highlightRectAtIndex:0];
			NSRect inDesktop = [desktop cg_highlightRectAtIndex:0];
			NSPoint desktopIconPosition = [[[desktop cg_positions] objectAtIndex:0] pointValue];
			NSRect desktopIcon = NSMakeRect(desktopIconPosition.x,
							[desktop bounds].size.height - desktopIconPosition.y
							- (CGFloat)[desktop iconSize],
							(CGFloat)[desktop iconSize], (CGFloat)[desktop iconSize]);

			check(near(NSWidth(inDesktop), NSWidth(inView)) && near(NSHeight(inDesktop), NSHeight(inView)),
			      "the two surfaces answer the same highlight SIZE for the same cell");
			/* **"THE SAME WAY" HAS TO BE SAID IN VISUAL TERMS, NOT IN y.** A file window is flipped and the desktop is
			 * not, so the name hanging BELOW the icon is a larger y in one and a smaller y in the other. What must match
			 * is the AIR above the icon and the AIR below it, whichever way the numbers run. */
			{
				CGFloat viewAirAbove = NSMinY(viewIcon) - NSMinY(inView);
				CGFloat viewAirBelow = NSMaxY(inView) - NSMaxY(viewIcon);
				CGFloat desktopAirAbove = NSMaxY(inDesktop) - NSMaxY(desktopIcon);
				CGFloat desktopAirBelow = NSMinY(desktopIcon) - NSMinY(inDesktop);
				CGFloat wantAirAbove = (CGFloat)WSIconHighlightInset;
				CGFloat wantAirBelow = (CGFloat)WSIconLabelGap + (CGFloat)WSIconLabelHeight
					+ (CGFloat)WSIconHighlightInset;

				check(near(NSMinX(inDesktop) - NSMinX(desktopIcon), NSMinX(inView) - NSMinX(viewIcon)),
				      "and sits the same way around the icon horizontally");
				check(near(viewAirAbove, wantAirAbove) && near(desktopAirAbove, wantAirAbove),
				      "with the same air above the icon in both — the name is on the other side");
				check(near(viewAirBelow, wantAirBelow) && near(desktopAirBelow, wantAirBelow),
				      "and the same room below it for the name");
			}
			check(near(NSWidth(inView), wantWidth) && near(NSHeight(inView), wantHeight),
			      "which is the cell's width and tall enough for the icon and the name");
		}

		/* THE VIEWS STAY: they registered for the shared selection, and a released observer is not this probe's business
		 * (a probe leaks two objects rather than freeing one the centre may still be holding). */
		(void)desktop;
		(void)desktopWindow;
	}

	/* 2. THE KEYBOARD MOVES THE SELECTION IN THE GRID. */
	[view selectIndex:0];
	[view keyDown:key(NSRightArrowFunctionKey, 0)];
	check([view selectedIndex] == 1, "Right moves to the next item");
	[view keyDown:key(NSDownArrowFunctionKey, 0)];
	check([view selectedIndex] == 4, "Down moves by one row of four columns");
	[view keyDown:key(NSUpArrowFunctionKey, 0)];
	check([view selectedIndex] == 0, "Up returns to the top row");
	[view keyDown:key(NSLeftArrowFunctionKey, 0)];
	check([view selectedIndex] == 0, "Left at the first cell stays there");
	[view keyDown:key(NSEndFunctionKey, 0)];
	check([view selectedIndex] == [view itemCount] - 1, "End selects the last item");
	[view keyDown:key(NSHomeFunctionKey, 0)];
	check([view selectedIndex] == 0, "Home selects the first");

	[view selectIndex:0];
	[view keyDown:key(NSRightArrowFunctionKey, NSShiftKeyMask)];
	check([[view selectedIndexes] containsIndex:0] && [[view selectedIndexes] containsIndex:1],
	      "Shift-Right extends the selection from the anchor");
	[view keyDown:key('a', NSCommandKeyMask)];
	check([[view selectedIndexes] count] == (NSUInteger)[view itemCount], "Command-A selects all");

	/* 3. TYPE-SELECT ACCUMULATES A PREFIX AND RESTARTS AFTER A SECOND. */
	[view selectIndex:-1];
	[view keyDown:key('d', 0)];
	check([view selectedIndex] == 1, "typing d selects delta.txt");
	[view keyDown:key('o', 0)];
	check([view selectedIndex] == 2, "and do selects Documents rather than restarting at d");

	/* 4. INLINE RENAME: A MOVE, A RELOAD, AND A REFUSAL. */
	[view selectIndex:indexNamed(view, @"delta.txt")];
	check([view beginRenamingSelectedItem], "Return/begin starts a rename over the label");
	check([[view cg_renameField] stringValue] != nil
	      && [[[view cg_renameField] stringValue] isEqual:@"delta.txt"],
	      "the field starts with the current name");
	[[view cg_renameField] setStringValue:@"renamed.txt"];
	check([view commitRenaming], "committing the field renames the file");
	check([[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"renamed.txt"]]
	      && ![[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"delta.txt"]],
	      "the file on disk has the new name");
	check([view selectedIndex] == indexNamed(view, @"renamed.txt"), "and the selection follows it");

	[view selectIndex:indexNamed(view, @"notes.txt")];
	check([view beginRenamingSelectedItem], "a second rename begins");
	[[view cg_renameField] setStringValue:@"other.txt"];
	[view cancelRenaming];
	check([[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"notes.txt"]]
	      && ![[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"other.txt"]],
	      "cancel leaves the file alone");

	[view selectIndex:indexNamed(view, @"notes.txt")];
	[view beginRenamingSelectedItem];
	[[view cg_renameField] setStringValue:@""];
	check(![view commitRenaming], "an empty name is refused");
	[view selectIndex:indexNamed(view, @"notes.txt")];
	[view beginRenamingSelectedItem];
	[[view cg_renameField] setStringValue:@"bad/name"];
	check(![view commitRenaming], "a slash is refused");

	/* 5. THE SOURCE PUTS THE SELECTED PATHS ON THE DRAG PASTEBOARD. */
	[view selectIndex:indexNamed(view, @"notes.txt")];
	{
		/* **THE EVENT'S LOCATION IS IN THE WINDOW'S SPACE, WHICH IS NOT THE VIEW'S** — this grid is flipped, so handing
		 * a view point over as a window point is a mirror, not an identity. The session converts from the window (see
		 * `NSDragging.m`), so the probe says what a real event says. */
		NSPoint iconPoint = centerOfIndex(view, [view selectedIndex]);
		NSEvent *drag = mouse(NSLeftMouseDragged, [view convertPoint:iconPoint toView:nil]);
		NSDraggingSession *session = [view cg_beginDragWithEvent:drag];
		id plist;

		check(session != nil && [NSDraggingSession cg_activeSession] == session,
		      "a selected icon begins the tier's drag session");
		plist = [[session draggingPasteboard] propertyListForType:NSFilenamesPboardType];
		check([plist isKindOfClass:[NSArray class]] && [plist count] == 1
		      && [[plist objectAtIndex:0] isEqual:[root stringByAppendingPathComponent:@"notes.txt"]],
		      "with the selected path on NSFilenamesPboardType");
		[window sendEvent:mouse(NSLeftMouseUp, [view convertPoint:iconPoint toView:nil])];
		check([NSDraggingSession cg_activeSession] == nil, "and the release ends it");
	}

	/* 5b. A REAL SESSION BETWEEN TWO WINDOWS: the source begins it, the destination is found by SCREEN point,
	 * the release performs it, and both models reload. */
	{
		WSItemModel *targetModel = [[WSItemModel alloc] initWithDirectory:target];
		WSIconView *targetView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								     model:targetModel];
		NSWindow *targetWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(500.0, 0.0, 400.0, 400.0)
								     styleMask:NSBorderlessWindowMask
								       backing:NSBackingStoreBuffered defer:NO];

		[targetWindow setContentView:targetView];
		[[NSApplication sharedApplication] cg_addWindow:window];
		[[NSApplication sharedApplication] cg_addWindow:targetWindow];
		[view selectIndex:indexNamed(view, @"notes.txt")];
		(void)[view cg_beginDragWithEvent:mouse(NSLeftMouseDragged, centerOfIndex(view, [view selectedIndex]))];
		[window sendEvent:mouse(NSLeftMouseDragged, NSMakePoint(520.0, 50.0))];
		[window sendEvent:mouse(NSLeftMouseUp, NSMakePoint(520.0, 50.0))];
		check([[NSFileManager defaultManager] fileExistsAtPath:
			[target stringByAppendingPathComponent:@"notes.txt"]]
		      && ![[NSFileManager defaultManager] fileExistsAtPath:
			[root stringByAppendingPathComponent:@"notes.txt"]],
		      "a drag from one window's icon view to another's moves the file");
		check([targetView itemCount] == 1 && indexNamed(view, @"notes.txt") == -1,
		      "and both models reloaded");
		[[NSApplication sharedApplication] cg_removeWindow:targetWindow];
		[[NSApplication sharedApplication] cg_removeWindow:window];
		[targetWindow release];
		[targetView release];
		[targetModel release];
	}

	/* 6. THE DROP POLICY IS A FACT ABOUT VOLUMES AND MODIFIERS. */
	check([view cg_proposedOperationForSameVolume:YES modifiers:0] == NSDragOperationMove,
	      "same volume, no modifier: Move");
	check([view cg_proposedOperationForSameVolume:YES modifiers:NSAlternateKeyMask] == NSDragOperationCopy,
	      "Option: Copy");
	check([view cg_proposedOperationForSameVolume:NO modifiers:0] == NSDragOperationCopy,
	      "another volume: Copy");
	check([view cg_proposedOperationForSameVolume:NO modifiers:NSCommandKeyMask] == NSDragOperationMove,
	      "Command across a volume: Move");
	check([view cg_proposedOperationForSameVolume:YES
					     modifiers:(NSAlternateKeyMask | NSCommandKeyMask)] == NSDragOperationLink,
	      "Command-Option: Link");

	/* 7. THE OPERATIONS THEMSELVES, AGAINST THE TWO VOLUMES. */
	{
		WSItemModel *targetModel = [[WSItemModel alloc] initWithDirectory:target];
		WSIconView *targetView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								     model:targetModel];

		check([targetView cg_performDropOfPaths:
			[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"move.txt"]]
			intoDirectory:target operation:NSDragOperationMove],
		      "Move performs a move into the destination folder");
		check([[NSFileManager defaultManager] fileExistsAtPath:[target stringByAppendingPathComponent:@"move.txt"]]
		      && ![[NSFileManager defaultManager] fileExistsAtPath:[sourceRoot stringByAppendingPathComponent:@"move.txt"]],
		      "and the source is gone");

		check([targetView cg_performDropOfPaths:
			[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"copy.txt"]]
			intoDirectory:target operation:NSDragOperationCopy],
		      "Copy leaves the source and makes the copy");
		check([[NSFileManager defaultManager] fileExistsAtPath:[target stringByAppendingPathComponent:@"copy.txt"]]
		      && [[NSFileManager defaultManager] fileExistsAtPath:[sourceRoot stringByAppendingPathComponent:@"copy.txt"]],
		      "both names exist");

		check([targetView cg_performDropOfPaths:
			[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"link.txt"]]
			intoDirectory:target operation:NSDragOperationLink],
		      "Link makes a link");
		check([[[NSFileManager defaultManager]
			destinationOfSymbolicLinkAtPath:[target stringByAppendingPathComponent:@"link.txt"] error:NULL]
			isEqual:[sourceRoot stringByAppendingPathComponent:@"link.txt"]],
		      "and it points at the source path");

		{
			WSItemModel *otherModel = [[WSItemModel alloc] initWithDirectory:otherTarget];
			WSIconView *otherView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
									 model:otherModel];

			check([otherView cg_performDropOfPaths:
				[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"copy.txt"]]
				intoDirectory:otherTarget operation:NSDragOperationCopy],
			      "a copy onto /dev/shm crosses a volume and performs");
			check([[NSFileManager defaultManager] fileExistsAtPath:
				[otherTarget stringByAppendingPathComponent:@"copy.txt"]]
			      && [[NSFileManager defaultManager] fileExistsAtPath:
				[sourceRoot stringByAppendingPathComponent:@"copy.txt"]],
			      "with the source still on the first volume");
			[otherView release];
			[otherModel release];
		}

		check(makeFile([target stringByAppendingPathComponent:@"conflict.txt"]), "a conflict is planted");
		check(makeFile([sourceRoot stringByAppendingPathComponent:@"conflict.txt"]), "on the source side");
		check(![targetView cg_performDropOfPaths:
			[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"conflict.txt"]]
			intoDirectory:target operation:NSDragOperationMove],
		      "an existing destination refuses the drop");
		check([[NSFileManager defaultManager] fileExistsAtPath:[sourceRoot stringByAppendingPathComponent:@"conflict.txt"]],
		      "and the source is untouched");

		[targetView release];
		[targetModel release];
	}

	/* 8. THE DESTINATION'S VIEW OF A DRAG: ENTER, DROP, AND A FOLDER AS THE TARGET. */
	{
		WSItemModel *rootModel = [[WSItemModel alloc] initWithDirectory:root];
		WSIconView *dropView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								   model:rootModel];
		NSWindow *dropWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								   styleMask:NSBorderlessWindowMask
								     backing:NSBackingStoreBuffered defer:NO];
		NSString *source = [sourceRoot stringByAppendingPathComponent:@"into-folder.txt"];
		NSPoint point = centerOfIndex(dropView, indexNamed(dropView, @"Target"));
		AGDropInfo *info = [[AGDropInfo alloc] initWithPaths:[NSArray arrayWithObject:source]
							    location:point mask:NSDragOperationEvery];
		NSDragOperation entered;

		[dropWindow setContentView:dropView];
		entered = [dropView draggingEntered:info];
		check(entered == NSDragOperationMove, "dropping on a folder icon targets that folder with Move");
		check([dropView performDragOperation:info], "and the drop is performed");
		check([[NSFileManager defaultManager]
			fileExistsAtPath:[target stringByAppendingPathComponent:@"into-folder.txt"]],
		      "the file landed inside the folder");
		[dropView draggingExited:info];
		[info release];
		[dropWindow release];
		[dropView release];
		[rootModel release];
	}

	/* 9. SPRING-LOADING ASKS THE APPLICATION FOR THE FOLDER'S WINDOW. */
	{
		WSItemModel *rootModel = [[WSItemModel alloc] initWithDirectory:root];
		WSIconView *dropView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								   model:rootModel];
		NSWindow *dropWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								   styleMask:NSBorderlessWindowMask
								     backing:NSBackingStoreBuffered defer:NO];
		NSPoint point = centerOfIndex(dropView, indexNamed(dropView, @"Target"));
		AGDropInfo *info = [[AGDropInfo alloc] initWithPaths:
			[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"copy.txt"]]
			location:point mask:NSDragOperationEvery];

		spring = [[AGSpringProbe alloc] init];
		[[NSNotificationCenter defaultCenter] addObserver:spring selector:@selector(requested:)
			name:WSIconViewRequestFolderWindowNotification object:nil];
		[dropWindow setContentView:dropView];
		(void)[dropView draggingEntered:info];
		[dropView cg_springOpen];
		check(spring->requests == 1 && [spring->path isEqual:target],
		      "a hovered folder asks for its window, with its path");
		[dropView draggingExited:info];
		[[NSNotificationCenter defaultCenter] removeObserver:spring];
		[spring release];
		[info release];
		[dropWindow release];
		[dropView release];
		[rootModel release];
	}

	/* 10. OPENING FROM THE KEYBOARD GOES THROUGH THE DELEGATE. */
	[view selectIndex:indexNamed(view, @"Documents")];
	[view keyDown:key(NSDownArrowFunctionKey, NSCommandKeyMask)];
	check(probe->opened != nil && [probe->opened isEqual:@"Documents"],
	      "Command-Down asks the delegate to open the selected folder/item");

	[probe release];
	[window release];
	[view release];
	[model release];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:sourceRoot error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:otherRoot error:NULL];

	printf("icon_view: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
