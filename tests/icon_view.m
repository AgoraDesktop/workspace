/*
 * icon_view — W3's icon view: the grid, the keyboard, rename, and the drop policies.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * **THE THREE HALVES ARE ASKED SEPARATELY.** The GRID is `WSIconLayout`'s left-to-right row order; the KEYBOARD and
 * TYPE-SELECT are `WSIconView`'s own state; the RENAME is a field over the label and an `NSFileManager` move; and the
 * DROP is the pasteboard's paths plus the policy arithmetic (same volume -> Move, across -> Copy, Command+Option ->
 * Link) and the file operation each policy performs. Offscreen, with a temporary tree on `/tmp` and a second on
 * `/dev/shm` so "across a volume" is a fact rather than a claim.
 */
#import "WSIconLabel.h"
#import "WSIconLayout.h"
#import "WSIconView.h"
#import "WSItemModel.h"

#import <AppKit/NSApplication.h>
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
		NSEvent *drag = mouse(NSLeftMouseDragged, centerOfIndex(view, [view selectedIndex]));
		NSDraggingSession *session = [view cg_beginDragWithEvent:drag];
		id plist;

		check(session != nil && [NSDraggingSession cg_activeSession] == session,
		      "a selected icon begins the tier's drag session");
		plist = [[session draggingPasteboard] propertyListForType:NSFilenamesPboardType];
		check([plist isKindOfClass:[NSArray class]] && [plist count] == 1
		      && [[plist objectAtIndex:0] isEqual:[root stringByAppendingPathComponent:@"notes.txt"]],
		      "with the selected path on NSFilenamesPboardType");
		[window sendEvent:mouse(NSLeftMouseUp, centerOfIndex(view, [view selectedIndex]))];
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
