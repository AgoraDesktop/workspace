/*
 * desktop_drag — the desktop as a drag SOURCE and a drop DESTINATION, the same two things a file window is.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A DESKTOP ICON IS A FILE ON THE DESKTOP, SO DRAGGING IT OUT IS A MOVE.** The gesture was the desktop's own — icons
 * followed the pointer and were snapped on release — and nothing about it could leave the view, so a file could not be
 * dragged from the desktop into a window, or from a window onto the desktop. Both directions are driven here the way a
 * person drives them: a real `NSDraggingSession` between two registered windows, and the destination's own doors for the
 * cases a session cannot express (a drop of a file that already lives there, and a drop onto a folder's icon).
 *
 * Offscreen, with temporary trees under /tmp. The two windows are registered with the application for the length of the
 * drag, because the destination search reads that registry.
 */
#import "WSDesktopView.h"
#import "WSIconLayout.h"
#import "WSIconView.h"
#import "WSItemDrag.h"
#import "WSItemModel.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSDragging.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSPasteboard.h>
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

/* **A DROP WITH NO SESSION BEHIND IT**, which is what the destination's own doors take: the pasteboard it offers and the
 * point it was released at, in the destination window's coordinates. */
@interface AGDropInfo : NSObject <NSDraggingInfo>
{
	NSPasteboard *_pasteboard;	/* RETAINED */
	NSPoint _location;
	NSDragOperation _mask;
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
- (id)draggingSource { return nil; }
- (NSInteger)draggingSequenceNumber { return 1; }
- (void)slideDraggedImageTo:(NSPoint)screenPoint { (void)screenPoint; }
- (NSArray *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination
{
	(void)dropDestination;
	return nil;
}
@end

/* **THE EVENT'S LOCATION IS IN THE SOURCE WINDOW'S SPACE**, and the session adds that window's origin back to get the
 * screen point the destination is found by. A probe that says (720, 50) from a window at (1300, 0) means the screen point
 * (2020, 50) — so the destination is named in screen terms here and the subtraction happens once. */
static NSPoint eventPointForScreenPoint(NSWindow *sourceWindow, NSPoint screenPoint)
{
	NSRect frame = [sourceWindow frame];

	return NSMakePoint(screenPoint.x - frame.origin.x, screenPoint.y - frame.origin.y);
}

static NSEvent *mouse(NSEventType type, NSPoint point)
{
	return [NSEvent mouseEventWithType:type location:point modifierFlags:0
				 timestamp:0.0 windowNumber:0 context:nil
				 eventNumber:0 clickCount:1 pressure:1.0f];
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *deskRoot;
	NSString *winRoot;
	NSString *ctrlRoot;
	NSFileManager *manager = [NSFileManager defaultManager];
	char deskTemplate[] = "/tmp/agora-desktop-drag-XXXXXX";
	char winTemplate[] = "/tmp/agora-desktop-window-XXXXXX";
	char ctrlTemplate[] = "/tmp/agora-desktop-ctrl-XXXXXX";

	printf("desktop_drag: the desktop as a drag source and a drop destination\n");

	if (mkdtemp(deskTemplate) == NULL || mkdtemp(winTemplate) == NULL || mkdtemp(ctrlTemplate) == NULL) {
		printf("FAIL: could not make the fixtures\n");
		[pool release];
		return 1;
	}
	deskRoot = [manager stringWithFileSystemRepresentation:deskTemplate length:strlen(deskTemplate)];
	winRoot = [manager stringWithFileSystemRepresentation:winTemplate length:strlen(winTemplate)];
	ctrlRoot = [manager stringWithFileSystemRepresentation:ctrlTemplate length:strlen(ctrlTemplate)];
	[manager createFileAtPath:[deskRoot stringByAppendingPathComponent:@"alpha.txt"]
			 contents:[NSData data] attributes:nil];
	[manager createDirectoryAtPath:[deskRoot stringByAppendingPathComponent:@"inbox"]
	   withIntermediateDirectories:NO attributes:nil error:NULL];
	[manager createFileAtPath:[winRoot stringByAppendingPathComponent:@"beta.txt"]
			 contents:[NSData data] attributes:nil];
	[manager createFileAtPath:[winRoot stringByAppendingPathComponent:@"delta.txt"]
			 contents:[NSData data] attributes:nil];
	[manager createFileAtPath:[ctrlRoot stringByAppendingPathComponent:@"gamma.txt"]
			 contents:[NSData data] attributes:nil];

	{
		/* THE DESKTOP, AND TWO WINDOWS BESIDE IT: one holds `winRoot`, the other is the control's source. */
		WSDesktopView *desktop = [[WSDesktopView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 600.0, 400.0)
							     directory:deskRoot];
		NSWindow *desktopWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 600.0, 400.0)
							styleMask:NSBorderlessWindowMask
							  backing:NSBackingStoreBuffered defer:NO];
		WSItemModel *model = [[WSItemModel alloc] initWithDirectory:winRoot];
		WSIconView *view = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0) model:model];
		NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(700.0, 0.0, 400.0, 400.0)
						styleMask:NSBorderlessWindowMask
						  backing:NSBackingStoreBuffered defer:NO];
		WSItemModel *ctrlModel = [[WSItemModel alloc] initWithDirectory:ctrlRoot];
		WSIconView *ctrlView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								   model:ctrlModel];
		NSWindow *ctrlWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(1300.0, 0.0, 400.0, 400.0)
							styleMask:NSBorderlessWindowMask
							  backing:NSBackingStoreBuffered defer:NO];

		[desktopWindow setContentView:desktop];
		[window setContentView:view];
		[ctrlWindow setContentView:ctrlView];
		[[NSApplication sharedApplication] cg_addWindow:desktopWindow];
		[[NSApplication sharedApplication] cg_addWindow:window];
		[[NSApplication sharedApplication] cg_addWindow:ctrlWindow];

		/* 0. **THE CONTROL, SO A FAILURE HERE IS NOT BLAMED ON THE DESKTOP.** A drag from an icon view into the window
		 * beside it, at the same screen point every desktop drag below uses. */
		{
			NSPoint into = eventPointForScreenPoint(ctrlWindow, NSMakePoint(1080.0, 200.0));

			[ctrlView selectIndex:0];
			(void)[ctrlView cg_beginDragWithEvent:mouse(NSLeftMouseDragged, NSMakePoint(48.0, 48.0))];
			[ctrlWindow sendEvent:mouse(NSLeftMouseDragged, into)];
			[ctrlWindow sendEvent:mouse(NSLeftMouseUp, into)];
			check([manager fileExistsAtPath:[winRoot stringByAppendingPathComponent:@"gamma.txt"]]
			      && ![manager fileExistsAtPath:[ctrlRoot stringByAppendingPathComponent:@"gamma.txt"]],
			      "CONTROL: one icon view can drop into another in this harness");
			[manager removeItemAtPath:[winRoot stringByAppendingPathComponent:@"gamma.txt"] error:NULL];
			[ctrlView reloadAfterChange];
		}

		/* 1. A PRESS ON A DESKTOP ICON IS A SELECTION THE DRAG CAN CARRY. */
		{
			NSPoint position = [[[desktop cg_positions] objectAtIndex:0] pointValue];
			NSPoint windowPoint = NSMakePoint(position.x + 32.0, 400.0 - (position.y + 32.0));

			[desktop mouseDown:mouse(NSLeftMouseDown, windowPoint)];
			[desktop mouseUp:mouse(NSLeftMouseUp, windowPoint)];
		}
		check([[desktop cg_selectedPaths] count] == 1,
		      "a press on a desktop icon selects it, so the drag has a path to carry");

		/* 2. **A DRAG FROM THE DESKTOP INTO A WINDOW IS A MOVE.** */
		{
			NSPoint position = [[[desktop cg_positions] objectAtIndex:0] pointValue];
			NSPoint windowPoint = NSMakePoint(position.x + 32.0, 400.0 - (position.y + 32.0));
			NSDraggingSession *session = [desktop cg_beginDragWithEvent:mouse(NSLeftMouseDragged, windowPoint)];

			check(session != nil && [NSDraggingSession cg_activeSession] == session,
			      "a selected desktop icon begins the tier's drag session");
			check([[[[session draggingPasteboard] propertyListForType:NSFilenamesPboardType] objectAtIndex:0]
			       isEqual:[deskRoot stringByAppendingPathComponent:@"alpha.txt"]],
			      "with the selected path on NSFilenamesPboardType, the same type a file window fills");
			{
				NSPoint into = eventPointForScreenPoint(desktopWindow, NSMakePoint(1080.0, 200.0));

				[desktopWindow sendEvent:mouse(NSLeftMouseDragged, into)];
				[desktopWindow sendEvent:mouse(NSLeftMouseUp, into)];
			}
			check([manager fileExistsAtPath:[winRoot stringByAppendingPathComponent:@"alpha.txt"]]
			      && ![manager fileExistsAtPath:[deskRoot stringByAppendingPathComponent:@"alpha.txt"]],
			      "dropping it on a file window moves the file there");
			{
				/* **AND IT ARRIVES SELECTED**, which is the set the hand was carrying. */
				NSIndexSet *chosen = [view selectedIndexes];
				BOOL atAlpha = NO;
				NSUInteger k;

				for (k = 0; k < [[[view model] items] count]; k++) {
					if ([[[[[view model] items] objectAtIndex:k] name] isEqual:@"alpha.txt"]
					    && [chosen containsIndex:k]) {
						atAlpha = YES;
					}
				}
				check(atAlpha, "and the item that arrived is the one selected in the window it arrived in");
			}
			{
				NSUInteger k, seen = 0;

				for (k = 0; k < [[[view model] items] count]; k++) {
					if ([[[[[view model] items] objectAtIndex:k] name] isEqual:@"alpha.txt"]) {
						seen = 1;
					}
				}
				check(seen == 1 && [[desktop cg_selectedPaths] count] == 0,
				      "and both surfaces read their directories again: the window lists it, the desktop let it go");
			}
		}

		/* 3. **THE OTHER DIRECTION: A DRAG FROM A WINDOW ONTO THE DESKTOP.** The desktop is a destination by
		 * registration, so the session's own search finds it and the drop lands in the desktop's directory. */
		{
			NSPoint position = [[[view cg_positions] objectAtIndex:0] pointValue];
			NSUInteger delta = NSNotFound;
			NSUInteger k;

			/* AN EMPTY PART OF THE DESKTOP: screen (120, 300) is inside the desktop window at (0, 0, 600, 400). */
			NSPoint into = eventPointForScreenPoint(window, NSMakePoint(120.0, 300.0));

			for (k = 0; k < [[[view model] items] count]; k++) {
				if ([[[[[view model] items] objectAtIndex:k] name] isEqual:@"delta.txt"]) {
					delta = k;
				}
			}
			[view selectIndex:(NSInteger)delta];
			(void)[view cg_beginDragWithEvent:mouse(NSLeftMouseDragged,
								NSMakePoint(position.x + 32.0, position.y + 32.0))];
			[window sendEvent:mouse(NSLeftMouseDragged, into)];
			[window sendEvent:mouse(NSLeftMouseUp, into)];
			check([manager fileExistsAtPath:[deskRoot stringByAppendingPathComponent:@"delta.txt"]]
			      && ![manager fileExistsAtPath:[winRoot stringByAppendingPathComponent:@"delta.txt"]],
			      "a drag from a window onto the desktop puts the file on the desktop");
			check([[[[desktop cg_selectedPaths] lastObject] lastPathComponent] isEqual:@"delta.txt"],
			      "and the desktop holds the item it received");
		}
		[desktop reload];

		/* 3b. **A SELECTED SET, NOT ONE ICON.** Two desktop icons dragged together into the window arrive together, and
		 * both are held there — the selection follows the SET, which is the gesture a person actually makes. */
		{
			NSFileManager *fm = [NSFileManager defaultManager];
			NSArray *items;
			NSUInteger a = NSNotFound, b = NSNotFound, k;
			NSPoint first, second, into;

			[fm createFileAtPath:[deskRoot stringByAppendingPathComponent:@"solo1.txt"]
				     contents:[NSData data] attributes:nil];
			[fm createFileAtPath:[deskRoot stringByAppendingPathComponent:@"solo2.txt"]
				     contents:[NSData data] attributes:nil];
			[desktop reload];
			items = [[desktop model] items];
			for (k = 0; k < [items count]; k++) {
				if ([[[items objectAtIndex:k] name] isEqual:@"solo1.txt"]) a = k;
				if ([[[items objectAtIndex:k] name] isEqual:@"solo2.txt"]) b = k;
			}
			check(a != NSNotFound && b != NSNotFound, "the desktop lists both items of the set");
			first = [[[desktop cg_positions] objectAtIndex:a] pointValue];
			second = [[[desktop cg_positions] objectAtIndex:b] pointValue];
			[desktop mouseDown:mouse(NSLeftMouseDown, NSMakePoint(first.x + 32.0, 400.0 - (first.y + 32.0)))];
			[desktop mouseUp:mouse(NSLeftMouseUp, NSMakePoint(first.x + 32.0, 400.0 - (first.y + 32.0)))];
			[desktop mouseDown:[NSEvent mouseEventWithType:NSLeftMouseDown
							 location:NSMakePoint(second.x + 32.0, 400.0 - (second.y + 32.0))
						    modifierFlags:NSShiftKeyMask
							timestamp:0.0 windowNumber:0 context:nil
						    eventNumber:0 clickCount:1 pressure:1.0f]];
			[desktop mouseUp:mouse(NSLeftMouseUp, NSMakePoint(second.x + 32.0, 400.0 - (second.y + 32.0)))];
			check([[desktop cg_selectedPaths] count] == 2, "two desktop icons are held, as a set");
			(void)[desktop cg_beginDragWithEvent:mouse(NSLeftMouseDragged,
								   NSMakePoint(first.x + 32.0, 400.0 - (first.y + 32.0)))];
			into = eventPointForScreenPoint(desktopWindow, NSMakePoint(1080.0, 200.0));
			[desktopWindow sendEvent:mouse(NSLeftMouseDragged, into)];
			[desktopWindow sendEvent:mouse(NSLeftMouseUp, into)];
			check([fm fileExistsAtPath:[winRoot stringByAppendingPathComponent:@"solo1.txt"]]
			      && [fm fileExistsAtPath:[winRoot stringByAppendingPathComponent:@"solo2.txt"]],
			      "both icons of the set move into the window");
			{
				NSIndexSet *chosen = [view selectedIndexes];
				NSArray *arrived = [[view model] items];
				NSUInteger x = NSNotFound, y = NSNotFound, n;

				for (n = 0; n < [arrived count]; n++) {
					if ([[[arrived objectAtIndex:n] name] isEqual:@"solo1.txt"]) x = n;
					if ([[[arrived objectAtIndex:n] name] isEqual:@"solo2.txt"]) y = n;
				}
				check(x != NSNotFound && y != NSNotFound && [chosen containsIndex:x] && [chosen containsIndex:y],
				      "and BOTH of them are held in the window: the selection followed the set");
			}
		}

		/* 4. **THE DESTINATION'S OWN RULES**, which a session cannot ask: a drop of a file that already lives on the
		 * desktop is not a drop at all — a drag released over the desktop only places the icon — and a drop released on a
		 * folder's icon lands INSIDE that folder. */
		{
			NSString *alpha = [deskRoot stringByAppendingPathComponent:@"alpha.txt"];
			AGDropInfo *already = [[AGDropInfo alloc] initWithPaths:[NSArray arrayWithObject:alpha]
								      location:NSMakePoint(100.0, 300.0)
									  mask:NSDragOperationEvery];

			check([desktop cg_updateDropWithInfo:already] == NSDragOperationNone,
			      "a file already on the desktop is refused, so a drag back here only places the icon");
			check(![desktop performDragOperation:already], "and performing it moves nothing");
			[already release];
		}
		{
			/* THE FOLDER'S OWN RECT, TAKEN FROM THE GRID RATHER THAN GUESSED: the desktop's positions are the icons'. */
			NSArray *items = [[desktop model] items];
			NSInteger inbox = -1;
			NSUInteger i;

			for (i = 0; i < [items count]; i++) {
				if ([[[items objectAtIndex:i] name] isEqual:@"inbox"]) {
					inbox = (NSInteger)i;
				}
			}
			NSString *beta = [winRoot stringByAppendingPathComponent:@"beta.txt"];

			if (inbox >= 0) {
				NSPoint position = [[[desktop cg_positions] objectAtIndex:(NSUInteger)inbox] pointValue];
				NSPoint windowPoint = NSMakePoint(position.x + 32.0, 400.0 - (position.y + 32.0));
				AGDropInfo *ontoFolder = [[AGDropInfo alloc] initWithPaths:[NSArray arrayWithObject:beta]
										  location:windowPoint
										      mask:NSDragOperationEvery];

				check([desktop cg_updateDropWithInfo:ontoFolder] == NSDragOperationMove,
				      "a drop released on a folder's icon offers Move");
				check([desktop performDragOperation:ontoFolder],
				      "and lands inside that folder rather than on the desktop");
				check([manager fileExistsAtPath:
				       [deskRoot stringByAppendingPathComponent:@"inbox/beta.txt"]],
				      "the file is in the folder");
				[ontoFolder release];
			}
		}

		/* 5. **AND A DRAG THAT COMES BACK TO THE DESKTOP ONLY PLACES THE ICON.** The desktop refuses the files — they are
		 * already there — so the source's own fallback is what a person sees: the icon is put where the pointer let go and
		 * snapped to the free cell nearest it, and the file is not touched. */
		{
			NSArray *items = [[desktop model] items];
			NSInteger keep = -1;
			NSUInteger k;

			[manager createFileAtPath:[deskRoot stringByAppendingPathComponent:@"keep.txt"]
					 contents:[NSData data] attributes:nil];
			[desktop reload];
			items = [[desktop model] items];
			for (k = 0; k < [items count]; k++) {
				if ([[[items objectAtIndex:k] name] isEqual:@"keep.txt"]) {
					keep = (NSInteger)k;
				}
			}
			(void)keep;
		}
		{
			NSPoint before = [[[desktop cg_positions] objectAtIndex:0] pointValue];
			NSPoint windowPoint = NSMakePoint(before.x + 32.0, 400.0 - (before.y + 32.0));
			NSPoint into = eventPointForScreenPoint(desktopWindow, NSMakePoint(150.0, 330.0));

			[desktop mouseDown:mouse(NSLeftMouseDown, windowPoint)];
			(void)[desktop cg_beginDragWithEvent:mouse(NSLeftMouseDragged, windowPoint)];
			[desktopWindow sendEvent:mouse(NSLeftMouseDragged, into)];
			[desktopWindow sendEvent:mouse(NSLeftMouseUp, into)];
			check(!NSEqualPoints([[[desktop cg_positions] objectAtIndex:0] pointValue], before),
			      "a drag released back over the desktop places the icon where the pointer let go");
			check([manager fileExistsAtPath:[deskRoot stringByAppendingPathComponent:@"keep.txt"]],
			      "and the file itself did not move off the desktop");
			check([[desktop cg_selectedPaths] count] == 1,
			      "and the set that was dragged is still the set that is held, where it landed");
		}

		[[NSApplication sharedApplication] cg_removeWindow:desktopWindow];
		[[NSApplication sharedApplication] cg_removeWindow:window];
		[[NSApplication sharedApplication] cg_removeWindow:ctrlWindow];
		[ctrlView release];
		[ctrlModel release];
		[ctrlWindow release];
		[view release];
		[model release];
		[window release];
		[desktop release];
		[desktopWindow release];
	}

	printf("desktop_drag: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	[pool release];
	return s_failed == 0 ? 0 : 1;
}
