/*
 * WSConflictSheet.h — the name conflict, asked rather than guessed.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * **A MODAL PANEL, NOT A SHEET, AND THAT IS STATED.** The operation's conflict handler is synchronous, and this tier
 * has no `NSPanel`/`NSAlert`; the question is put in a small modal window with Replace, Skip, Keep Both and Cancel.
 * The answer is `WSFileOperations`' conflict resolution, so the file operation and the dialog cannot disagree.
 */
#ifndef WORKSPACE_WSCONFLICTSHEET_H
#define WORKSPACE_WSCONFLICTSHEET_H

#import <AppKit/NSWindow.h>

#import "WSFileOperations.h"

@interface WSConflictSheet : NSWindow
{
	NSString *_destination;
}
+ (WSFileConflictResolution)askWithDestination:(NSString *)destination parentWindow:(nullable NSWindow *)parent;
- (instancetype)initWithDestination:(NSString *)destination;
- (WSFileConflictResolution)run;
@end

#endif /* WORKSPACE_WSCONFLICTSHEET_H */
