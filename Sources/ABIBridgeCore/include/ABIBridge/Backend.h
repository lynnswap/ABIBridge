#pragma once

// Backend transport shared by package targets and ABI fixtures.
#include <ABIBridge/ABIBridge.h>
#include <ABIBridge/Backend/Runtime.h>
#include <ABIBridge/Backend/Demangling.h>
#include <ABIBridge/Backend/Invocation.h>
#include <ABIBridge/Backend/NativeDispatch.h>
#include <ABIBridge/Backend/PointerSlot.h>
#include <ABIBridge/Backend/ImportedHooks.h>
#include <ABIBridge/Backend/ImportedHookMonitoring.h>
#include <ABIBridge/Backend/ManagedVirtualEntry.h>
#include <ABIBridge/Backend/ImageObservation.h>
#include <ABIBridge/Backend/SwiftDemangling.h>
#include <ABIBridge/Backend/SwiftInvocation.h>
#include <ABIBridge/Backend/SwiftCallbacks.h>
#include <ABIBridge/Backend/SwiftProtocolConformance.h>
