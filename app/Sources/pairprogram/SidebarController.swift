import AppKit

/// The right-hand panel: Comments | Pull Requests.
final class SidebarController: NSViewController {
    enum Tab: Int { case comments, pullRequests }

    let comments: CommentsPanel
    let pullRequests: PullRequestList
    private let switcher = NSSegmentedControl()
    private let container = NSView()
    private(set) var tab = Tab.comments

    init(comments: CommentsPanel, pullRequests: PullRequestList) {
        self.comments = comments
        self.pullRequests = pullRequests
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        switcher.segmentCount = 2
        for (i, (symbol, label, tip)) in [("text.bubble", "Comments", "Comments (⌥⌘1)"), ("arrow.triangle.pull", "Pull Requests", "Pull requests (⌥⌘2)")].enumerated() {
            switcher.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular)), forSegment: i)
            switcher.setLabel(label, forSegment: i)
            switcher.setImageScaling(.scaleProportionallyDown, forSegment: i)
            switcher.setToolTip(tip, forSegment: i)
            switcher.setWidth(0, forSegment: i)
        }
        switcher.font = .systemFont(ofSize: 11.5)
        switcher.segmentDistribution = .fillEqually
        switcher.selectedSegment = 0
        switcher.target = self
        switcher.action = #selector(switched)
        for v in [switcher, container] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            switcher.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            switcher.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            switcher.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for vc in [comments, pullRequests] as [NSViewController] {
            addChild(vc)
            vc.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(vc.view)
            NSLayoutConstraint.activate([
                vc.view.topAnchor.constraint(equalTo: container.topAnchor),
                vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        view = root
        show(.comments)
    }

    func show(_ tab: Tab) {
        self.tab = tab
        switcher.selectedSegment = tab.rawValue
        comments.view.isHidden = tab != .comments
        pullRequests.view.isHidden = tab != .pullRequests
        if tab == .pullRequests { pullRequests.refresh() }
    }

    @objc private func switched() { show(Tab(rawValue: switcher.selectedSegment) ?? .comments) }
}
