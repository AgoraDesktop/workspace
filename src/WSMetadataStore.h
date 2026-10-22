/*
 * WSMetadataStore.h — a directory's own metadata: where its icons are, and how big they are.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * THIS IS THE `.DS_Store` QUESTION, ANSWERED THE TREE'S OWN WAY (WORKSPACE-PLAN.md §5.1). The Mac's MODEL is
 * followed — a per-folder sidecar beside the items — and the FORMAT and the FILENAME are Agora's, because the
 * format is what the plan says is ours to choose: a property list, and a name this tree owns (`.agora`), not
 * Apple's private one. THE ENCODING IS XML, because that is what this tree's `NSPropertyListSerialization`
 * writes — MEASURED: it refuses the binary format — and a sidecar that diffs is one a person can inspect.
 *
 * ICON POSITIONS ARE IN TOP-LEFT SCREEN COORDINATES, which is the reference file manager's own convention and the one a
 * persisted position should have: the view converts to Cocoa's bottom-left only when it draws.
 */
#ifndef WORKSPACE_WSMETADATASTORE_H
#define WORKSPACE_WSMETADATASTORE_H

#import <Foundation/NSGeometry.h>
#import <Foundation/NSObject.h>

@class NSString;

@interface WSMetadataStore : NSObject
{
	NSString *_directory;
	id _positions;			/* name -> [x, y] */
	NSInteger _iconSize;
}

/* Read the sidecar beside `directory` if there is one; a directory with none is not an error. */
+ (instancetype)storeForDirectory:(NSString *)directory;

- (BOOL)hasIconPositionForName:(NSString *)name;
- (NSPoint)iconPositionForName:(NSString *)name;	/* NSZeroPoint when unset */
- (void)setIconPosition:(NSPoint)position forName:(NSString *)name;
- (void)removeIconPositionForName:(NSString *)name;

- (NSInteger)iconSize;
- (void)setIconSize:(NSInteger)size;

/* Write the sidecar. NO if it could not be written; the caller may ignore that, but it is told. */
- (BOOL)save;

@end

#endif /* WORKSPACE_WSMETADATASTORE_H */
