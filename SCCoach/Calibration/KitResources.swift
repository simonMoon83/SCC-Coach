import Foundation

// SCCoachKit 번들 리소스 접근점 — RegionStore(1단계)가 기본 경로로 쓰고,
// 테스트가 리소스 배선을 검증할 때 사용한다.
public enum KitResources {
    public static func regionsURL(named name: String = "regions-1920x1080") -> URL? {
        Bundle.module.url(forResource: name, withExtension: "json")
    }
}
