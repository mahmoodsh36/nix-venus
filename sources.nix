# Source pins for the UTM and Khronos forks behind the darwin host stack.
{
  # utmapp virglrenderer branch macos (osy open virgl MRs).
  virglrenderer = {
    rev  = "71a67414013f120c158729da7f56f29b55bf4f6c";
    hash = "sha256-k/yk3RGam6Xj7ZmY37jEJgXaA3+qrilyFDUJtX2ebJM=";
  };

  # utmapp libepoxy branch macos-venus. Stock nixpkgs libepoxy
  # disables EGL on darwin. This branch wires up ANGLE.
  libepoxy = {
    rev  = "15d904dcb1d5a8d626ffe11e8f3339499d6f7b09";
    hash = "sha256-NTjklUW3Tpb7IwuXxtU1ANoK1f6iGt+54p4A+CGBmio=";
  };

  # The MoltenVK fork pins Vulkan-Headers 1.4.334. nixpkgs 1.4.328 lacks
  # for example VkPhysicalDeviceShaderFmaFeaturesKHR. The loader must match
  # the headers version or nixpkgs marks it broken.
  vulkanSdk = {
    version      = "1.4.335.0";
    headersHash  = "sha256-DIePLzDoImnaso0WYUv819wSDeA7Zy1I/tYAbsALXKg=";
    loaderHash   = "sha256-1xLT4AynJumzwkYOBS5i0OpCi3EdE8QctctDn+DGrvU=";
  };

  # utmapp MoltenVK branch macos, 3 fixes ahead of Khronos needed
  # for stable Venus on Metal interop.
  moltenvk = {
    rev  = "6f2002d1a583c3347827cbce1c1b8a33aeec2077";
    hash = "sha256-wYBRMscfiyrKpqjoyGTJ6ukhTLTNlkSvJ/h1kfTxl3Q=";
  };
}
