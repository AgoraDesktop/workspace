/*
 * WSItemDrag.m — what a drop into a directory means, and the drag that carries it there.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSItemDrag.h"

#import <AppKit/NSDragging.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSPasteboard.h>
#import <Foundation/Foundation.h>

#include <sys/stat.h>

/* ---- the two facts a drop needs about the file system ------------------------------------------ */

static BOOL fn_same_volume(NSArray *paths, NSString *directory)
{
	struct stat target;
	NSUInteger i;

	if (stat([directory UTF8String], &target) != 0) {
		return YES;	/* can't tell: the local default is Move, and the operation will report its own failure */
	}
	for (i = 0; i < [paths count]; i++) {
		struct stat source;
		NSString *path = [paths objectAtIndex:i];

		if (stat([path UTF8String], &source) == 0 && source.st_dev != target.st_dev) {
			return NO;
		}
	}
	return YES;
}

static BOOL fn_all_from_directory(NSArray *paths, NSString *directory)
{
	NSUInteger i;

	for (i = 0; i < [paths count]; i++) {
		NSString *parent = [[paths objectAtIndex:i] stringByDeletingLastPathComponent];

		if (![parent isEqual:directory]) {
			return NO;
		}
	}
	return YES;
}

static BOOL fn_directory_is_inside_any(NSString *directory, NSArray *paths)
{
	NSUInteger i;

	for (i = 0; i < [paths count]; i++) {
		NSString *path = [paths objectAtIndex:i];

		if ([directory isEqual:path] || [directory hasPrefix:[path stringByAppendingString:@"/"]]) {
			return YES;
		}
	}
	return NO;
}

NSDraggingSession *WSItemDragBegin(NSView *view, NSArray *paths, NSArray *items, NSEvent *event,
				   id <NSDraggingSource> source)
{
	NSPasteboard *pasteboard;

	if ([paths count] == 0 || [items count] == 0) {
		return nil;
	}
	pasteboard = [NSPasteboard pasteboardWithName:NSDragPboard];
	[pasteboard clearContents];
	[pasteboard declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType] owner:nil];
	[pasteboard setPropertyList:paths forType:NSFilenamesPboardType];
	return [view beginDraggingSessionWithItems:items event:event source:source];
}

NSArray *WSItemDragPaths(id <NSDraggingInfo> info)
{
	id plist = [[info draggingPasteboard] propertyListForType:NSFilenamesPboardType];

	return [plist isKindOfClass:[NSArray class]] ? plist : nil;
}

NSDragOperation WSItemDragOperationForVolume(BOOL sameVolume, NSDragOperation sourceMask, NSUInteger modifiers)
{
	BOOL option = (modifiers & NSAlternateKeyMask) != 0;
	BOOL command = (modifiers & NSCommandKeyMask) != 0;
	NSDragOperation operation;

	if (option && command) {
		operation = NSDragOperationLink;
	} else if (option) {
		operation = NSDragOperationCopy;
	} else if (sameVolume) {
		operation = NSDragOperationMove;
	} else if (command) {
		operation = NSDragOperationMove;
	} else {
		operation = NSDragOperationCopy;
	}
	return operation & sourceMask;
}

NSDragOperation WSItemDragOperation(NSArray *paths, NSString *target, NSDragOperation sourceMask,
				    NSUInteger modifiers)
{
	if ([paths count] == 0 || target == nil) {
		return NSDragOperationNone;
	}
	/* **A FILE ALREADY THERE IS NOT A DROP, AND A FOLDER INSIDE THE DRAG IS A HOLE.** Both are refused before a
	 * modifier is read: Option could ask for a copy of a file into the directory it already sits in, which the
	 * preflight in `WSItemDragPerform` would then refuse anyway — one answer, given here. */
	if (fn_all_from_directory(paths, target) || fn_directory_is_inside_any(target, paths)) {
		return NSDragOperationNone;
	}
	return WSItemDragOperationForVolume(fn_same_volume(paths, target), sourceMask, modifiers);
}

BOOL WSItemDragPerform(NSArray *paths, NSString *target, NSDragOperation operation)
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSUInteger i;

	if ([paths count] == 0 || target == nil || operation == NSDragOperationNone) {
		return NO;
	}
	/* PREFLIGHT EVERY DESTINATION BEFORE MOVING ANYTHING: a conflict halfway through a multi-file drag is a partial
	 * result nobody asked for. W6's conflict sheet is what will make this a question rather than a refusal. */
	for (i = 0; i < [paths count]; i++) {
		NSString *source = [paths objectAtIndex:i];
		NSString *destination = [target stringByAppendingPathComponent:[source lastPathComponent]];

		if (![manager fileExistsAtPath:source] || [manager fileExistsAtPath:destination]) {
			return NO;
		}
		if ([target isEqual:source] || [target hasPrefix:[source stringByAppendingString:@"/"]]) {
			return NO;
		}
	}
	for (i = 0; i < [paths count]; i++) {
		NSString *source = [paths objectAtIndex:i];
		NSString *destination = [target stringByAppendingPathComponent:[source lastPathComponent]];
		BOOL ok = NO;

		if (operation == NSDragOperationMove) {
			ok = [manager moveItemAtPath:source toPath:destination error:NULL];
		} else if (operation == NSDragOperationCopy) {
			ok = [manager copyItemAtPath:source toPath:destination error:NULL];
		} else if (operation == NSDragOperationLink) {
			/* A SYMBOLIC LINK, NOT A CARBON ALIAS: the bookmark record is `WSAlias` (W6), and this is the link
			 * operation that exists today. The header says so where the modifier is described. */
			ok = [manager createSymbolicLinkAtPath:destination withDestinationPath:source error:NULL];
		}
		if (!ok) {
			return NO;
		}
	}
	return YES;
}
