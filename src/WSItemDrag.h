/*
 * WSItemDrag.h — the half of a drag that is about the FILE SYSTEM, so every surface plays by one rule.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A DRAG IS TWO THINGS: A VIEW'S GESTURE AND A RULE ABOUT FILES.** The gesture is the view's — the pointer, the
 * pixels, which cell it is over, whether a folder springs open — and it stays in `WSIconView`. The rule is not: what a
 * drop into a directory means, whether a drop is refused because the file already lives there or because the target is
 * inside the thing being dragged, and what Command and Option do to the operation. A file window and the desktop are
 * both drag sources and both destinations, so that half lives here, once, and the two surfaces cannot drift into two
 * answers to the same question.
 *
 * `NSFilenamesPboardType` is the one type spoken here: every application in this tree declares it, and a drag that
 * crosses a process boundary crosses with the pasteboard's own names rather than a translation — see
 * `NSDragging.h` in the AppKit.
 */
#ifndef WORKSPACE_WSITEMDRAG_H
#define WORKSPACE_WSITEMDRAG_H

#import <AppKit/NSDragging.h>
#import <Foundation/NSGeometry.h>
#import <Foundation/NSObject.h>

@class NSEvent;
@class NSDraggingSession;
@class NSView;
@class WSFileOperations;

/* **THE SOURCE'S HALF: ONE PASTEBOARD, ONE SESSION.** `paths` is what the drag offers, `items` are the
 * `NSDraggingItem`s the caller built (each with its own frame and picture). A drag that offers nothing is not one, and
 * returns nil. */
NSDraggingSession *WSItemDragBegin(NSView *view, NSArray *paths, NSArray *items, NSEvent *event,
				   id <NSDraggingSource> source);

/* **A SOURCE WHOSE ITEMS HAVE MOVED HAS TO READ ITS DIRECTORY AGAIN**, and the destination is what knows it moved them.
 * A view that drags from a folder answers this; the destination asks by selector, so it needs no class and the two
 * surfaces do not have to know about each other. */
@protocol WSItemDragSourceReloading <NSObject>
- (void)reloadAfterChange;
@end

/* **AND THE ITEMS A DROP PUT HERE ARE THE ONES THE HAND MEANT**, so the surface that received them selects them: a set
 * dragged out of the desktop arrives selected in the window, and the same set let go over the desktop stays selected where
 * it landed. A destination asks by selector, like the reload above, so neither surface has to know the other. */
@protocol WSItemDragSelectionTaking <NSObject>
- (void)cg_selectPaths:(NSArray *)paths;
@end

/* The paths on a destination's dragging info, or nil when the drag carries none. */
NSArray *WSItemDragPaths(id <NSDraggingInfo> info);

/* **THE MODIFIERS' ANSWER, GIVEN THE ONE FACT A VIEW MAY ALREADY KNOW.** Command on a cross-volume drop is Move and
 * Option is Copy; Option plus Command is Link whatever the volumes are. Nothing else is consulted, so a caller holding
 * only "same volume?" gets the same answer the drop itself would. */
NSDragOperation WSItemDragOperationForVolume(BOOL sameVolume, NSDragOperation sourceMask, NSUInteger modifiers);

/* **WHAT A DROP INTO `target` WOULD DO**, honouring the source's own mask. `NSDragOperationNone` when there is nothing
 * to do: no paths, no target, every file already in `target`, or a target inside one of the dragged directories. */
NSDragOperation WSItemDragOperation(NSArray *paths, NSString *target, NSDragOperation sourceMask,
				    NSUInteger modifiers);

/* And doing it: every destination is preflighted before anything moves, so a conflict halfway through a multi-file drag
 * is a refusal rather than a partial result. */
BOOL WSItemDragPerform(NSArray *paths, NSString *target, NSDragOperation operation);

/* **AND THE SAME MOVE, THROUGH THE WINDOW'S OPERATIONS, SO IT CAN BE UNDONE.** A view that has a `WSFileOperations` hands
 * it in and a Move is performed by it — the same MOVE, with the undo entry the Edit menu needs. Copy and Link have no
 * such owner here and fall through to the plain answer. A view with no operations (a probe, a surface that was made
 * without one) keeps the old behaviour rather than dropping the gesture. */
BOOL WSItemDragPerformWithOperations(NSArray *paths, NSString *target, NSDragOperation operation,
				     WSFileOperations *operations);

/* **AND THE SAME PATHS ON THE GENERAL PASTEBOARD, WHICH IS WHAT A COPY IS.** A drag puts them on `NSDragPboard` for the
 * length of the gesture; a Copy leaves them on the pasteboard every application reads, in the one type this tree speaks.
 * Nothing is marked or removed: the pasteboard is a place to put an offer, and what a paste makes of it belongs to
 * whoever pastes. */
void WSItemCopyPathsToPasteboard(NSArray *paths);

/* **A CUT IS THE SAME OFFER WITH A PROMISE ATTACHED** — "and take them away when you use it" — which is the one thing a
 * pasteboard property list cannot say, so this process remembers it. A paste asks which it was, performs the operation it
 * promised, and forgets it: a second paste of the same cut has nothing left to move. */
void WSItemCutPathsToPasteboard(NSArray *paths);
NSArray *WSItemClipboardPaths(BOOL *wasCut);
void WSItemClipboardForget(void);

#endif /* WORKSPACE_WSITEMDRAG_H */
