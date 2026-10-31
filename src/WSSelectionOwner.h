/*
 * WSSelectionOwner.h — the ONE selection a Workspace has, shared by every icon surface.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A DESKTOP IS ONE PLACE, SO ITS HIGHLIGHT IS ONE THING.** The desktop and every file window are separate views with
 * separate models — their own items, their own grid — and until now their selections were separate too: an icon could be
 * highlighted on the desktop and another in each open window at the same time, which says "these are all chosen" about
 * files in three different folders. A file manager's selection is a fact about the desktop, not about a view, so there is
 * one of it and it lives wherever the person last chose something.
 *
 * **THE CLAIM IS A NOTIFICATION AND NOT A THIRD OBJECT**, because the views already know how to say what they hold: a view
 * whose selection becomes non-empty posts this, naming ITSELF as the sender, and every other view drops what it had. A
 * view that clears itself posts nothing — clicking in the empty space of one window is not choosing anything, so the
 * window next door keeps its own selection, which is the Mac's behaviour and the reason "deselected" and "not chosen
 * here" are different states.
 *
 * The views that take part are the icon surfaces: `WSIconView` (every file window) and `WSDesktopView`. The list and
 * column views of a file window keep their own row selection, which is stated in their headers rather than implied here.
 */
#ifndef WORKSPACE_WSSELECTIONOWNER_H
#define WORKSPACE_WSSELECTIONOWNER_H

#import <Foundation/NSString.h>

/* **POSTED BY THE VIEW THAT NOW HOLDS THE SELECTION, WITH ITSELF AS `object`.** A receiver that is not that object drops
 * its own selection; a receiver that is clears nothing, because it is the one being announced. */
extern NSString *WSSelectionDidChangeNotification;

#endif /* WORKSPACE_WSSELECTIONOWNER_H */
