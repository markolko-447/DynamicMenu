//
//  Goo.metal
//  DynamicMenu
//
//  The sharpening half of the pill's fluid effect. The pill and its bubbles
//  are drawn as soft blobs; blurred together, blobs that are close join into one
//  smooth mass. This turns that soft result back into a crisp shape: anything
//  above the cut-off becomes solid, anything below disappears, with a narrow
//  ramp between so edges stay smooth.
//

#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 gooThreshold(float2 position, half4 color, float cut, float softness) {
    half edge = smoothstep(half(cut - softness), half(cut + softness), color.a);
    return half4(0.0h, 0.0h, 0.0h, edge);
}
