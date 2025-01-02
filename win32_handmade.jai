#import "Basic";
#import "Windows";

WINDOW_CLASS_NAME :: "HandmadeHeroWindowClass";
WINDOW_NAME :: "Handmade Hero";

main :: () {
    MessageBoxA(
    	null,
    	"This is Handmade Hero.",
    	"Handmade Hero",
    	MB_ICONINFORMATION | MB_OK,
    );
}