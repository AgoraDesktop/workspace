/*
 * WSItemKind.h — the Kind column's one question, answered by Launch Services.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE TYPE ANSWER IS F1'S, NOT AN EXTENSION TABLE IN THE VIEW.** `LSCopyKindStringForURL` is Launch Services'
 * own door, fed by the Agora bundles in this tree; a directory is "Folder" because that is what a person reads. When
 * the registry has nothing to say (an unregistered extension, or no declaring bundle), the fallback is named rather
 * than hidden: the extension, or "Document" when there is none.
 */
#ifndef WORKSPACE_WSITEMKIND_H
#define WORKSPACE_WSITEMKIND_H

#import <Foundation/NSObject.h>

@class NSString;
@class WSItem;

@interface WSItemKind : NSObject
+ (NSString *)kindForItem:(WSItem *)item;
@end

#endif /* WORKSPACE_WSITEMKIND_H */
