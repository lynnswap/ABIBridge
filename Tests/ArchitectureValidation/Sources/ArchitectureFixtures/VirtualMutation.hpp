#pragma once

namespace ABIVTable {
struct Primary {
    int seed = 10;
    virtual int value(int) const;
};
struct Secondary {
    int secondarySeed = 20;
    virtual int adjusted(int) const;
    virtual Secondary *identity();
};
struct Derived final : Primary, Secondary {
    int ownSeed;
    explicit Derived(int value): ownSeed(value) {}
    int value(int) const override;
    int adjusted(int) const override;
    Derived *identity() override;
};
int primaryOracle(const Primary *, int);
int secondaryOracle(const Secondary *, int);
Secondary *covariantOracle(Secondary *);
int directOracle(const Derived *, int);
}
