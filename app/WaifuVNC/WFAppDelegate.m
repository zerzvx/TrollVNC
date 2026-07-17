#import "WFAppDelegate.h"

// App companion minimalista de Waifu VNC: muestra el estado del tweak (daemon + API de control).
@implementation WFAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor colorWithRed:0.055 green:0.04 blue:0.075 alpha:1.0];

    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppIcon60x60"]];
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.layer.cornerRadius = 30.0; iv.clipsToBounds = YES;
    iv.layer.borderWidth = 2.0; iv.layer.borderColor = [UIColor colorWithRed:1 green:0.176 blue:0.57 alpha:1].CGColor;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:iv];

    UILabel *title = [UILabel new];
    title.text = @"Waifu VNC 💗"; title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:28];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:title];

    UILabel *status = [UILabel new];
    status.numberOfLines = 0; status.textAlignment = NSTextAlignmentCenter;
    status.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    status.font = [UIFont systemFontOfSize:16];
    status.text = @"Comprobando el daemon…";
    status.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:status];

    [NSLayoutConstraint activateConstraints:@[
        [iv.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor constant:-100],
        [iv.widthAnchor constraintEqualToConstant:130], [iv.heightAnchor constraintEqualToConstant:130],
        [title.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:22],
        [title.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [status.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:16],
        [status.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:28],
        [status.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-28],
    ]];

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // consultar el estado del tweak por su API de control local
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:46900/rpc"]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [@"{\"method\":\"info\"}" dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 5;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSString *txt;
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([j isKindOfClass:[NSDictionary class]] && [j[@"ok"] boolValue]) {
            NSDictionary *sc = j[@"screen"];
            txt = [NSString stringWithFormat:@"✅ Daemon activo\nVNC :5901  ·  Control API :46900\nPantalla %@ × %@",
                   sc[@"w"], sc[@"h"]];
        } else {
            txt = @"⚠️ El daemon no responde en :46900\nComprueba que Waifu VNC esté cargado.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{ status.text = txt; });
    }] resume];

    return YES;
}

@end
